Shell script to spawn commands within a network namespace with the only
visible network link being Mullvad WireGuard tunnel connected to a random
server (within a certain country and/or city).

Namespaces can be brought up once by root and then used by unprivileged users
through `mullvad-netns exec`, without needing `sudo` for every command.

The configuration lives at `/etc/mullvad-netns/config`, it is a shell script
that is sourced when the program is run. There is a default configuration
installed that defines some variables. The location of the configuration file
can be also overriden by setting the `MULLVAD_NETNS_CONF` environment variable.

As a quick start, one should set their account number. The default location
of this file is `/etc/mullvad-netns/account`. This file must not be readable
by anyone other than root.

```text
Usage:
  mullvad-netns up [-n <name>] [options]
  mullvad-netns exec [-n <name>] [--] <command>
  mullvad-netns down [-f] [-a | <name>...]
  mullvad-netns list
  mullvad-netns [run] [options] [--] <command>

Run <command> under a network namespace connected to a randomly selected
Mullvad server over WireGuard as the only visible network device. This
ensures that the command does not have access to the network except through
the Mullvad tunnel.

Commands
  up                         bring up a namespace and print its name
                               (requires root)
  exec                       run <command> as the current user in a namespace
                               that is up
  down                       take namespaces down (requires root)
  list                       list the namespaces that are up
  run                        bring up a namespace, run <command> in it as the
                               user that ran sudo, and take it down again once
                               nothing runs in it any more (requires root, the
                               default when no subcommand is given)

Options
  -n, --name <name>          name of the namespace, for exec this can be left
                               out when only one namespace is up
  -C, --country <regex>      use only servers from countries matching the
                               given regular expression
  -c, --city <regex>         use only servers from cities matching the
                               given regular expression

  -4, --ipv4                 connect to the Mullvad server over IPv4 (the default)
  -6, --ipv6                 connect to the Mullvad server over IPv6

  -a, --all                  take down all namespaces
  -f, --force                take down namespaces even if processes still run
                               in them, they keep the tunnel until they exit

  -h, --help                 display this help
```

When `--country` is given without `--city`, servers from any city in the
matching countries are used. Otherwise the `CITY` from the configuration
applies.

## Example

```console
$ sudo mullvad-netns up -C sweden
se-got-wg-001
$ mullvad-netns exec -- firefox
$ mullvad-netns list
se-got-wg-001  se-got-wg-001  Gothenburg, Sweden
$ sudo mullvad-netns down
```

For a one-off command, `sudo mullvad-netns -C sweden -- <command>` brings up a
namespace, runs the command as the user that ran `sudo`, and takes the
namespace down again afterwards.

## Entering namespaces without root

`mullvad-netns exec` uses `mullvad-netns-exec`, a small helper installed with
the `cap_sys_admin` file capability (this is what `make install` sets up). In
the same way as [switch-netns](https://github.com/USSURATONCACHI/switch-netns),
it joins the network namespace and then executes the command with all
privileges dropped. It only enters namespaces brought up by `mullvad-netns`,
and keeps environment variables such as `TMPDIR` and `LD_LIBRARY_PATH` that the
C library otherwise removes from programs that gain privileges.

## DNS

Changing the network namespace is not enough to keep name lookups inside the
tunnel. With the default `nsswitch.conf` of many distributions, lookups go to
`systemd-resolved` (or avahi for `.local` names) over a unix socket, which
resolves them outside of the namespace.

So like `ip netns exec`, `mullvad-netns-exec` runs the command in a private
mount namespace that has the namespace's own `resolv.conf` and
`nsswitch.conf` bind mounted over the ones in `/etc`:

- `resolv.conf` lists the `NAMESERVERS` from the configuration, by default
  only Mullvad's resolver inside the tunnel (`10.64.0.1`)
- `nsswitch.conf` is the system one with the `hosts` line replaced by
  `NSSWITCH_HOSTS` (`files myhostname dns`)

If these files can't be applied, the command is not run. They are also linked
to `/etc/netns/<name>` before the namespace is created, so `ip netns exec` and
tools that follow its convention apply them too.

Programs can still reach services outside of the namespace through unix
sockets, such as D-Bus. If `nscd` is running with its hosts cache enabled,
lookups go through it and leave the tunnel, so disable that cache.

## Installing

```console
$ make
$ sudo make install
```

Packages that can't set file capabilities while building can pass `SETCAP=:`
and run `setcap cap_sys_admin=ep /usr/bin/mullvad-netns-exec` when the package
is installed instead.

Completions for fish are installed to
`/usr/share/fish/vendor_completions.d/`. They complete subcommands, namespaces,
and country and city names from the cached server list.
