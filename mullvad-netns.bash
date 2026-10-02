#!/usr/bin/env bash
#
# Author: Patrick McLean <chutzpah@gentoo.org>
#
# SPDX-License-Identifier: GPL-2.0+

CONFIG_FILE=${MULLVAD_NETNS_CONF:-"/etc/mullvad-netns/config"}

# all these variables can be overriden in the config file
MULLVAD_PORT=51820
RELAYS_URI="https://api.mullvad.net/public/relays/wireguard/v1/"
MULLVAD_API_URI="https://api.mullvad.net/wg/"

# the default country to select a server from, list of available countries is available with
# curl https://api.mullvad.net/public/relays/wireguard/v1/ | jq  ".countries[].name"
# defaults to USA
COUNTRY="usa"

# the default city to select a server from, list of available cities withing a country available with
#curl -s https://api.mullvad.net/public/relays/wireguard/v1/ | jq ".countries[] | select(.name == \"${COUNTRY}\") | .cities[].name"
# defaults to any server in California, only used when --country is not given
CITY=", ca"

# file name to find the account in
ACCOUNT_FILENAME="/etc/mullvad-netns/account"

# directory to store keys in
WG_KEYFILE="/etc/mullvad-netns/privatekey"

# location of cache of servers list
SERVERS_CACHE="/var/cache/mullvad-netns/mullvad-servers.json"

# how often to refresh cache of mullvad servers
SERVERS_CACHE_MAX_AGE="1 day"

# location to load nftables rules from
NFTABLES_RULESET="/etc/mullvad-netns/rules.nft"

# list of nameservers to use inside the netns, defaults to the resolver Mullvad
# runs inside the tunnel
NAMESERVERS=(
	"10.64.0.1"
)

# hosts line of the nsswitch.conf used inside the netns, this keeps name lookups
# from going to resolvers outside of the netns that are reached through a unix
# socket (systemd-resolved, avahi), set to empty to use the system nsswitch.conf
NSSWITCH_HOSTS="files myhostname dns"

# helper that enters a netns as an unprivileged user
EXEC_HELPER="mullvad-netns-exec"

# these are also compiled in to mullvad-netns-exec, so they are not configurable
readonly NETNS_RUN_DIR="/run/netns"
readonly NETNS_ETC_DIR="/etc/netns"
readonly STATE_DIR="/run/mullvad-netns"

# make sure these are empty
declare -a TEMPFILES=()
unset cleanup_netns


cleanup() {
	rm -rf "${TEMPFILES[@]}"

	# remove the network namespace if it's empty
	[[ -n ${cleanup_netns} && -z $(ip netns pids "${cleanup_netns}" 2>/dev/null) ]] \
		&& netns_teardown "${cleanup_netns}"
}

_curl() {
	# drop privliges and run curl
	runuser -u nobody -- curl --location --fail --fail-early --silent --show-error "${@}"
}

_jq() {
	# drop privliges and run jq
	runuser -u nobody -- jq "${@}"
}

_trim_spaces() {
	: "${1#"${1%%[![:space:]]*}"}"
	: "${_%"${_##*[![:space:]]}"}"
	printf '%s\n' "$_"
}

mullvad_update_server_list() {
	# atomically update the mullvad server list cache
	if [[ ! -d ${SERVERS_CACHE%/*} ]]; then
		mkdir -p "${SERVERS_CACHE%/*}" || return
	fi

	TEMPFILES+=("$(mktemp "${SERVERS_CACHE%/*}/.mullvad-servers-XXXXXX.json")") || return
	local tempfile="${TEMPFILES[-1]}"
	_curl "${RELAYS_URI}" | _jq . > "${tempfile}" || { rm -f "${tempfile}"; return 1; }
	chmod 0644 "${tempfile}" || return
	mv -f "${tempfile}" "${SERVERS_CACHE}"
}

mullvad_select_random_server() {
	local country="${1}" city="${2}"

	if [[ -r ${SERVERS_CACHE} ]]; then
		if [[ $(date -u -r "${SERVERS_CACHE}" +%s) -lt $(date -u --date="-${SERVERS_CACHE_MAX_AGE}" +%s) ]]; then
			mullvad_update_server_list || return
		fi
	else
		mullvad_update_server_list || return
	fi

	local -a server_list
	readarray -t server_list < <(_jq -r --arg country "${country}" --arg city "${city}" '
			.countries[] | select(.name | test($country; "i")) | .name as $country_name
			| .cities[] | select(.name | test($city; "i")) | .name as $city_name
			| .relays[]
			| [.hostname, .public_key, .ipv4_addr_in, .ipv6_addr_in, $city_name, $country_name]
			| join("|")' "${SERVERS_CACHE}"); wait "${!}" || return

	local server_count="${#server_list[@]}"
	if [[ ${server_count} -eq 0 ]]; then
		printf -- '%s: No Mullvad servers match country "%s" and city "%s"\n' "${progname}" "${country}" "${city}" >&2
		return 1
	fi

	printf -- '%s\n' "${server_list[$((RANDOM % server_count))]}"
}

mullvad_set_local_ips() {
	local pubkey="${1}"
	local account_lines account

	if [[ ! -r ${ACCOUNT_FILENAME} ]]; then
		printf -- '%s: Could not find Mullvad account file at "%s"\n' "${progname}" "${ACCOUNT_FILENAME}" >&2
		return 1
	elif  [[ $(($(stat --format='0%a' "${ACCOUNT_FILENAME}") & 0133)) -ne 0 ]]; then
		printf -- '%s: Mullvad account file "%s" should not be readable or writeable by others\n' "${progname}" "${ACCOUNT_FILENAME}" >&2
		return 1
	elif ! readarray -t account_lines < "${ACCOUNT_FILENAME}"; then
		printf -- '%s: Cound not read Mullvad account from "%s"\n' "${progname}" "${ACCOUNT_FILENAME}" >&2
		return 1
	fi

	local account_line
	for account_line in "${account_lines[@]}"; do
		[[ ${account_line} == \#* ]] && continue
		if [[ ${account_line} =~ ^[[:space:]]*((([0-9]{4}[[:space:]]+){3}[0-9]{4})|[0-9]{16})[[:space:]]*(#.*|)$ ]]; then
			account="$(_trim_spaces "${account_line%#*}")"
		else
			printf -- '%s: WARNING skipping invalid account "%s"\n' "${progname}" "${account_line}" >&2
			continue
		fi
	done

	if [[ ! ${account} =~ ^((([0-9]{4}[[:space:]]+){3}[0-9]{4})|[0-9]{16})$ ]]; then
		printf -- '%s: Could not find valid Mullvad account in "%s"\n' "${progname}" "${ACCOUNT_FILENAME}" >&2
		return 1
	fi

	local address
	address="$(_curl "${MULLVAD_API_URI}" \
		-d account="${account// /}" \
		--data-urlencode pubkey="${pubkey}")" || return

	if [[ ! ${address} =~ ^[0-9.]+/[0-9]{1,2},[a-f0-9:]+/[0-9]{1,3}$ ]]; then
		printf -- '%s\n' "${address}" >&2
		return 1
	fi

	IFS=',' read -r local_ipv4 local_ipv6 <<< "${address}" || return
}

get_wireguard_keys() {
	local keyfile="${WG_KEYFILE:-/etc/wireguard/mullvad/privatekey}"
	local keydir="${keyfile%/*}"

	if [[ ! -d ${keydir} ]]; then
		mkdir -p "${keydir}" || return
		chmod 0755 "${keydir}" || return
	fi

	local privatekey pubkey
	if [[ -r ${keyfile} ]]; then
		if  [[ $(($(stat --format='0%a' "${keyfile}") & 0133)) -ne 0 ]]; then
			printf -- '%s: Private key file "%s" should not be readable or writeable by others\n' "${progname}" "${keyfile}" >&2
			return 1
		fi
		privatekey="$(<"${keyfile}")" || return
	else
		privatekey=$(set -o pipefail; umask 077; wg genkey | tee "${keyfile}") || return
	fi

	pubkey="$(wg pubkey <<< "${privatekey}")" || return

	printf -- '%s %s\n' "${privatekey}" "${pubkey}"
}


setup_interface() {
	# scripts that get run for the final steps
	local -a address_script=(
		"address add ${local_ipv4} dev ${linkname}"
	)
	local -a address6_script=(
		"address add ${local_ipv6} dev ${linkname}"
	)
	local -a linkup_script=(
		"link set up dev lo"
		"link set up dev ${linkname}"
	)
	local -a routes_script=(
		"route add default dev ${linkname} scope global"
	)
	local -a routes6_script=(
		"route add default dev ${linkname} scope global"
	)

	# initial setup, the wireguard link is created outside of the netns so its
	# encrypted traffic goes out through the regular network
	ip netns add "${netns}" || return
	if ! ip link add dev "${linkname}" type wireguard; then
		ip netns del "${netns}"
		return 1
	fi
	if ! ip link set dev "${linkname}" netns "${netns}"; then
		ip link del dev "${linkname}"
		ip netns del "${netns}"
		return 1
	fi

	# configure the wireguard interface in the netns
	if ! ip netns exec "${netns}" wg set "${linkname}" \
			private-key <(printf -- '%s\n' "${private_key}") \
			peer "${pubkey}" \
			allowed-ips '0.0.0.0/0,::0/0' \
			endpoint "${endpoint}"
	then
		ip netns del "${netns}"
		return 1
	fi

	# load nftables rules in to netns before bringing up interface
	if [[ -n ${NFTABLES_RULESET} && -r ${NFTABLES_RULESET} ]]; then
		if ! ip netns exec "${netns}" nft -f "${NFTABLES_RULESET}"; then
			ip netns del "${netns}"
			return 1
		fi
	fi

	# configure addresses on interfaces, bring them up and initialize the routes
	if ! (
		set -e
		ip -family inet -netns "${netns}" -batch - <<< "$(printf -- "%s\n" "${address_script[@]}")"
		ip -family inet6 -netns "${netns}" -batch - <<< "$(printf -- "%s\n" "${address6_script[@]}")"
		ip -netns "${netns}" -batch - <<< "$(printf -- "%s\n" "${linkup_script[@]}")"
		ip -family inet -netns "${netns}" -batch - <<< "$(printf -- "%s\n" "${routes_script[@]}")"
		ip -family inet6 -netns "${netns}" -batch - <<< "$(printf -- "%s\n" "${routes6_script[@]}")"
	); then

		ip netns del "${netns}"
		return 1
	fi

	return 0
}

setup_netns_files() {
	# write the state of the netns, including the files that get bind mounted
	# over /etc inside it, to a temporary directory first so they are complete
	# once they appear
	if [[ ! -d ${STATE_DIR} ]]; then
		mkdir -p "${STATE_DIR}" || return
		chmod 0755 "${STATE_DIR}" || return
	fi

	TEMPFILES+=("$(mktemp -d "${STATE_DIR}/.${netns}-XXXXXX")") || return
	local tempdir="${TEMPFILES[-1]}"

	mkdir "${tempdir}/etc" || return
	printf "nameserver %s\n" "${NAMESERVERS[@]}" > "${tempdir}/etc/resolv.conf" || return

	if [[ -n ${NSSWITCH_HOSTS} && -r /etc/nsswitch.conf ]]; then
		local line
		while IFS= read -r line || [[ -n ${line} ]]; do
			[[ ${line} =~ ^[[:space:]]*hosts[[:space:]]*: ]] && line="hosts: ${NSSWITCH_HOSTS}"
			printf -- '%s\n' "${line}"
		done < /etc/nsswitch.conf > "${tempdir}/etc/nsswitch.conf" || return
	fi

	printf -- '%s=%s\n' \
		server "${linkname}" \
		city "${city_name}" \
		country "${country_name}" \
		endpoint "${endpoint}" \
		> "${tempdir}/info" || return

	chmod -R u=rwX,go=rX "${tempdir}" || return
	mv -T "${tempdir}" "${STATE_DIR}/${netns}" || return

	# let `ip netns exec` and the like use the same files
	if [[ ! -d ${NETNS_ETC_DIR} ]]; then
		mkdir -p "${NETNS_ETC_DIR}" || return
		chmod 0755 "${NETNS_ETC_DIR}" || return
	fi
	ln -sfnT "${STATE_DIR}/${netns}/etc" "${NETNS_ETC_DIR}/${netns}"
}

valid_name() {
	# mullvad-netns-exec checks names in the same way
	[[ ${1} =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$ ]]
}

netns_name_taken() {
	local name="${1}"

	[[ -e ${NETNS_RUN_DIR}/${name} || -e ${STATE_DIR}/${name} ]] && return 0

	# only replace /etc/netns entries that are links left over from a previous boot
	if [[ -e ${NETNS_ETC_DIR}/${name} || -L ${NETNS_ETC_DIR}/${name} ]]; then
		[[ $(readlink -- "${NETNS_ETC_DIR}/${name}") != "${STATE_DIR}/${name}/etc" ]] && return 0
	fi

	return 1
}

name_netns() {
	local requested="${1}"
	local name="${requested:-${linkname}}" counter=0

	# make sure the network namespace name isn't already in use
	while netns_name_taken "${name}"; do
		if [[ -n ${requested} ]]; then
			printf -- '%s: Namespace name "%s" is already in use\n' "${progname}" "${name}" >&2
			return 1
		fi
		((counter++))
		name="${linkname}-${counter}"
	done

	if ! valid_name "${name}"; then
		printf '%s: could not find a valid netns name\n' "${progname}" >&2
		return 1
	fi

	netns="${name}"
}

netns_up() {
	# bring up a netns connected to a random server, setting netns to its name
	if [[ -n ${name} ]] && ! valid_name "${name}"; then
		printf -- '%s: Invalid namespace name "%s"\n' "${progname}" "${name}" >&2
		return 1
	fi

	local private_key public_key
	read -r private_key public_key < <(get_wireguard_keys); wait "${!}" || return

	local linkname pubkey ipv4_addr ipv6_addr city_name country_name
	IFS='|' read -r linkname pubkey ipv4_addr ipv6_addr city_name country_name < \
		<(mullvad_select_random_server "${country}" "${city}"); wait "${!}" || return

	name_netns "${name}" || return

	local local_ipv4 local_ipv6
	mullvad_set_local_ips "${public_key}" || return ${?}

	local endpoint
	if [[ -n ${ipv6} ]]; then
		endpoint="[${ipv6_addr}]:${MULLVAD_PORT}"
	else
		endpoint="${ipv4_addr}:${MULLVAD_PORT}"
	fi

	# the files that keep DNS inside the netns must be in place before it can be
	# entered, from here on take everything down again if anything fails
	cleanup_netns="${netns}"
	setup_netns_files || return
	setup_interface
}

netns_teardown() {
	local name="${1}"

	if [[ -e ${NETNS_RUN_DIR}/${name} ]]; then
		ip netns del "${name}" || return
	fi

	if [[ -L ${NETNS_ETC_DIR}/${name} && $(readlink -- "${NETNS_ETC_DIR}/${name}") == "${STATE_DIR}/${name}/etc" ]]; then
		rm -f -- "${NETNS_ETC_DIR:?}/${name}"
	fi
	rm -rf -- "${STATE_DIR:?}/${name:?}"
}

list_netns() {
	# print the names of the namespaces brought up by mullvad-netns
	local dir
	for dir in "${STATE_DIR}"/*/; do
		[[ -d ${dir} ]] || continue
		dir="${dir%/}"
		printf -- '%s\n' "${dir##*/}"
	done
}

default_netns() {
	# use the only namespace that is up if none was given
	local -a names
	readarray -t names < <(list_netns)

	case ${#names[@]} in
		0)
			printf -- '%s: No namespace is up, bring one up with "sudo %s up"\n' "${progname}" "${progname}" >&2
			return 1
		;;
		1) name="${names[0]}";;
		*)
			printf -- '%s: More than one namespace is up, select one with --name: %s\n' "${progname}" "${names[*]}" >&2
			return 1
		;;
	esac
}

require_root() {
	if [[ ${EUID} -ne 0 ]]; then
		printf -- '%s: superuser privileges required\n' "${progname}" >&2
		return 1
	elif [[ $(id --group) -ne 0 ]]; then
		printf -- '%s: must be run with GID 0\n' "${progname}" >&2
		return 1
	fi
}

find_exec_helper() {
	if ! helper="$(command -v "${EXEC_HELPER}")"; then
		printf -- '%s: Could not find "%s"\n' "${progname}" "${EXEC_HELPER}" >&2
		return 1
	fi
}

load_config() {
	# source the config file if it exists
	[[ -r ${CONFIG_FILE} ]] || return 0

	# when not running as root, the config can't do anything the user couldn't do anyway
	if [[ ${EUID} -eq 0 ]]; then
		if [[ $(stat --format='%u:%g' "${CONFIG_FILE}") != 0:0 ]]; then
			printf -- '%s: Config file "%s" must be owned by root:root\n' "${progname}" "${CONFIG_FILE}" >&2
			return 1
		elif [[ $(($(stat --format='0%a' "${CONFIG_FILE}") & 0122)) -ne 0 ]]; then
			printf -- '%s: Config file "%s" must not be writeable by group or other\n' "${progname}" "${CONFIG_FILE}" >&2
			return 1
		fi
	fi

	source "${CONFIG_FILE}"
}

show_usage() {
	printf 'Usage:\n'
	printf '  %s up [-n <name>] [options]\n' "${progname}"
	printf '  %s exec [-n <name>] [--] <command>\n' "${progname}"
	printf '  %s down [-f] [-a | <name>...]\n' "${progname}"
	printf '  %s list\n' "${progname}"
	printf '  %s [run] [options] [--] <command>\n\n' "${progname}"
	printf 'Run <command> under a network namespace connected to a randomly selected\n'
	printf 'Mullvad server over WireGuard as the only visible network device. This\n'
	printf 'ensures that the command does not have access to the network except through\n'
	printf 'the Mullvad tunnel.\n\nCommands\n'
	printf '  up                         bring up a namespace and print its name\n'
	printf '                               (requires root)\n'
	printf '  exec                       run <command> as the current user in a namespace\n'
	printf '                               that is up\n'
	printf '  down                       take namespaces down (requires root)\n'
	printf '  list                       list the namespaces that are up\n'
	printf '  run                        bring up a namespace, run <command> in it as the\n'
	printf '                               user that ran sudo, and take it down again once\n'
	printf '                               nothing runs in it any more (requires root, the\n'
	printf '                               default when no subcommand is given)\n\n'
	printf 'Options\n'
	printf '  -n, --name <name>          name of the namespace, for exec this can be left\n'
	printf '                               out when only one namespace is up\n'
	printf '  -C, --country <regex>      use only servers from countries matching the\n'
	printf '                               given regular expression\n'
	printf '  -c, --city <regex>         use only servers from cities matching the\n'
	printf '                               given regular expression\n\n'
	printf '  -4, --ipv4                 connect to the Mullvad server over IPv4 (the default)\n'
	printf '  -6, --ipv6                 connect to the Mullvad server over IPv6\n\n'
	printf '  -a, --all                  take down all namespaces\n'
	printf '  -f, --force                take down namespaces even if processes still run\n'
	printf '                               in them, they keep the tunnel until they exit\n\n'
	printf '  -h, --help                 display this help\n'
}

parse_args() {
	# parse command line options of the subcommand, setting the variables of
	# the same name in the caller, with the remaining arguments in args
	local short long
	case ${subcommand} in
		up) short='n:C:c:46h' long='name:,country:,city:,ipv4,ipv6,help';;
		exec) short='+n:h' long='name:,help';;
		down) short='afh' long='all,force,help';;
		list) short='h' long='help';;
		run) short='+C:c:46h' long='country:,city:,ipv4,ipv6,help';;
	esac

	local params
	if ! params="$(getopt -o "${short}" -l "${long}" -n "${progname}" -- "${@}")"; then
		show_usage
		return 1
	fi

	eval set -- "${params}"
	while [[ ${#} -gt 0 ]]; do
		case ${1} in
			-n|--name) name="${2}"; shift;;
			-C|--country) country=${2}; shift;;
			-c|--city) city="${2}"; shift;;
			-4|--ipv4)
				if [[ -n ${ipv6} ]]; then
					printf -- '%s: cannot specify both --ipv4 and --ipv6\n' "${progname}" >&2
					return 1
				fi
				ipv4=1
			;;
			-6|--ipv6)
				if [[ -n ${ipv4} ]]; then
					printf -- '%s: cannot specify both --ipv4 and --ipv6\n' "${progname}" >&2
					return 1
				fi
				ipv6=1
			;;
			-a|--all) all=1;;
			-f|--force) force=1;;
			-h|--help) show_usage; exit 0;;
			--) shift; break;;
		esac
		shift
	done

	args=("${@}")

	case ${subcommand} in
		up|list)
			if [[ ${#args[@]} -gt 0 ]]; then
				printf -- '%s: Unexpected argument "%s"\n' "${progname}" "${args[0]}" >&2
				return 1
			fi
		;;
		exec|run)
			if [[ ${#args[@]} -eq 0 ]]; then
				printf '%s: Must specify a command to run\n' "${progname}"
				show_usage
				return 1
			fi
		;;
	esac

	# the configured city is only meant for the configured country
	if [[ ${subcommand} == @(up|run) && ! -v country ]]; then
		country="${COUNTRY}"
		city="${city-${CITY}}"
	fi
}

cmd_up() {
	local name country city ipv4 ipv6
	local -a args
	parse_args "${@}" || return
	require_root || return

	local netns
	netns_up || return

	# keep the netns around
	unset cleanup_netns
	printf -- '%s\n' "${netns}"
}

cmd_exec() {
	local name
	local -a args
	parse_args "${@}" || return

	if [[ -z ${name} ]]; then
		default_netns || return
	fi

	local helper
	find_exec_helper || return
	exec "${helper}" "${name}" -- "${args[@]}"
}

cmd_down() {
	local all force
	local -a args
	parse_args "${@}" || return
	require_root || return

	local -a names=("${args[@]}")
	if [[ -n ${all} ]]; then
		if [[ ${#names[@]} -gt 0 ]]; then
			printf -- '%s: cannot specify both --all and namespace names\n' "${progname}" >&2
			return 1
		fi
		readarray -t names < <(list_netns)
	elif [[ ${#names[@]} -eq 0 ]]; then
		local name
		default_netns || return
		names=("${name}")
	fi

	local name ret=0
	for name in "${names[@]}"; do
		if ! valid_name "${name}" || [[ ! -d ${STATE_DIR}/${name} ]]; then
			printf -- '%s: "%s" is not a namespace brought up by %s\n' "${progname}" "${name}" "${progname}" >&2
			ret=1
		elif [[ -z ${force} && -e ${NETNS_RUN_DIR}/${name} && -n $(ip netns pids "${name}") ]]; then
			printf -- '%s: Processes are still running in "%s", use --force to take it down anyway\n' "${progname}" "${name}" >&2
			ret=1
		else
			netns_teardown "${name}" || ret=1
		fi
	done

	return ${ret}
}

cmd_list() {
	local -a args
	parse_args "${@}" || return

	local name key value
	local -A info
	while read -r name; do
		info=()
		while IFS='=' read -r key value; do
			info[${key}]="${value}"
		done < "${STATE_DIR}/${name}/info"

		printf -- '%s\t%s\t%s, %s' "${name}" "${info[server]}" "${info[city]}" "${info[country]}"
		[[ -e ${NETNS_RUN_DIR}/${name} ]] || printf ' (stale)'
		printf '\n'
	done < <(list_netns) | column -t -s $'\t'
}

cmd_run() {
	local name country city ipv4 ipv6
	local -a args
	parse_args "${@}" || return
	require_root || return

	if [[ -z ${SUDO_USER} ]]; then
		printf '%s: SUDO_USER is unset, cannot run command as user\n' "${progname}" >&2
		return 1
	fi

	local helper
	find_exec_helper || return

	local netns
	netns_up || return

	# cleanup takes the netns down again once the command is done with it
	runuser --pty --shell="$(command -v bash)" \
		--command="$(printf -- '%q ' "${helper}" "${netns}" -- "${args[@]}")" \
		- "${SUDO_USER}"
}

main() {
	set -o pipefail
	local progname="${BASH_SOURCE[0]##*/}"
	trap cleanup EXIT

	load_config || return

	if [[ ${#} -eq 0 ]]; then
		show_usage
		return 1
	fi

	local subcommand=run
	case ${1} in
		up|exec|down|list|run) subcommand="${1}"; shift;;
		help) show_usage; return 0;;
	esac

	"cmd_${subcommand}" "${@}"
}

main "${@}"
