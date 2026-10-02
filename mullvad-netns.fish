# Completions for mullvad-netns

set -l subcommands up exec down list run help

function __fish_mullvad_netns_subcommand -d "Print the subcommand, run if none is given"
    set -l cmd (commandline -xpc)
    if set -q cmd[2]; and contains -- $cmd[2] up exec down list run help
        echo $cmd[2]
    else
        echo run
    end
end

function __fish_mullvad_netns_print_remaining_args -d "Print the command to run in the namespace, once it has started"
    set -l tokens (commandline -xpc | string escape) (commandline -ct)
    set -e tokens[1]
    set -l subcommand (__fish_mullvad_netns_subcommand)
    if test "$tokens[1]" = $subcommand
        set -e tokens[1]
    else if not set -q tokens[2]
        # The first argument is completed as a subcommand
        return 1
    end

    set -l opts
    switch $subcommand
        case run
            set opts C/country= c/city= 4/ipv4 6/ipv6 h/help
        case exec
            set opts n/name= h/help
        case '*'
            return 1
    end
    argparse -s $opts -- $tokens 2>/dev/null
    or return

    # The remaining argv is the command with all its arguments
    if set -q argv[1]; and not string match -qr '^-' -- $argv[1]
        string join0 -- $argv
    else
        return 1
    end
end

function __fish_complete_mullvad_netns_subcommand
    set -l args (__fish_mullvad_netns_print_remaining_args | string split0)
    set -q args[1]
    and __fish_complete_subcommand --commandline $args
end

function __fish_mullvad_netns_using -d "Test if the subcommand is one of the given ones, and still takes options"
    contains -- (__fish_mullvad_netns_subcommand) $argv
    and not __fish_mullvad_netns_print_remaining_args >/dev/null
end

function __fish_mullvad_netns_config -a name -d "Print a variable from the mullvad-netns config"
    # Only simple assignments are understood
    set -l config /etc/mullvad-netns/config
    test -r $config; or return
    set -l values (string match -rg "^\s*$name=[\"']?([^\"']*)" <$config)
    and echo $values[-1]
end

function __fish_mullvad_netns_servers -d "Print the path of the cached Mullvad server list"
    set -l servers (__fish_mullvad_netns_config SERVERS_CACHE)
    or set servers /var/cache/mullvad-netns/mullvad-servers.json
    test -r $servers; and echo $servers
end

function __fish_mullvad_netns_namespaces -d "List the namespaces brought up by mullvad-netns"
    for dir in /run/mullvad-netns/*/
        test -r $dir/info; or continue
        set -l location (string match -rg '^(?:city|country)=(.*)' <$dir/info)
        printf '%s\t%s\n' (path basename -- $dir) (string join ', ' -- $location)
    end
end

function __fish_mullvad_netns_countries -d "List the countries with Mullvad servers"
    set -l servers (__fish_mullvad_netns_servers); or return
    jq -r '.countries[] | "\(.name)\t\([.cities[].relays[]] | length) servers"' $servers 2>/dev/null
end

function __fish_mullvad_netns_cities -d "List the cities with Mullvad servers in the selected countries"
    set -l servers (__fish_mullvad_netns_servers); or return

    set -l tokens (commandline -xpc)
    set -e tokens[1]
    contains -- "$tokens[1]" up run; and set -e tokens[1]
    # Leave out the option whose value is being completed
    contains -- "$tokens[-1]" -c --city; and set -e tokens[-1]

    set -l country
    if argparse -s n/name= C/country= c/city= 4/ipv4 6/ipv6 h/help -- $tokens 2>/dev/null
        and set -q _flag_country
        set country $_flag_country[-1]
    else
        # Like mullvad-netns, use the configured country
        set country (__fish_mullvad_netns_config COUNTRY)
        or set country usa
    end

    jq -r --arg country "$country" '
        .countries[] | select(.name | test($country; "i")) | .name as $country
        | .cities[] | "\(.name)\t\($country), \(.relays | length) servers"' $servers 2>/dev/null
end

complete -c mullvad-netns -f

# Subcommands
complete -c mullvad-netns -n __fish_is_first_arg -a up -d "Bring up a namespace"
complete -c mullvad-netns -n __fish_is_first_arg -a exec -d "Run a command in a namespace"
complete -c mullvad-netns -n __fish_is_first_arg -a down -d "Take down namespaces"
complete -c mullvad-netns -n __fish_is_first_arg -a list -d "List the namespaces"
complete -c mullvad-netns -n __fish_is_first_arg -a run -d "Run a command in a temporary namespace"
complete -c mullvad-netns -n __fish_is_first_arg -a help -d "Display help"

# Options
complete -c mullvad-netns -n "__fish_mullvad_netns_using up" -s n -l name -x -d "Name of the namespace"
complete -c mullvad-netns -n "__fish_mullvad_netns_using exec" -s n -l name -x -a "(__fish_mullvad_netns_namespaces)" -d "Namespace to run the command in"
complete -c mullvad-netns -n "__fish_mullvad_netns_using up run" -s C -l country -x -a "(__fish_mullvad_netns_countries)" -d "Use servers in countries matching regex"
complete -c mullvad-netns -n "__fish_mullvad_netns_using up run" -s c -l city -x -a "(__fish_mullvad_netns_cities)" -d "Use servers in cities matching regex"
complete -c mullvad-netns -n "__fish_mullvad_netns_using up run; and not __fish_seen_argument -s 6 -l ipv6" -s 4 -l ipv4 -d "Connect to the server over IPv4"
complete -c mullvad-netns -n "__fish_mullvad_netns_using up run; and not __fish_seen_argument -s 4 -l ipv4" -s 6 -l ipv6 -d "Connect to the server over IPv6"
complete -c mullvad-netns -n "__fish_mullvad_netns_using down" -s a -l all -d "Take down all namespaces"
complete -c mullvad-netns -n "__fish_mullvad_netns_using down" -s f -l force -d "Take down namespaces that are still in use"
complete -c mullvad-netns -n "__fish_mullvad_netns_using $subcommands" -s h -l help -d "Display help"

# Namespaces to take down
complete -c mullvad-netns -n "__fish_mullvad_netns_using down; and not __fish_seen_argument -s a -l all" -a "(__fish_mullvad_netns_namespaces)"

# Complete the command to run in the namespace
complete -c mullvad-netns -a "(__fish_complete_mullvad_netns_subcommand)"
