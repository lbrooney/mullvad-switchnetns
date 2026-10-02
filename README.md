Shell script to spawn a command within a network namespace with the only
visible network link being Mullvad WireGuard tunnel connected to a random
server (within a certain country and/or city).

The configuration lives at `/etc/mullvad-netns/config`, it is a shell script
that is sourced when the program is run. There is a default configuration
installed that defines some variables. The location of the configuration file
can be also overriden by setting the `MULLVAD_NETNS_CONF` environment variable.

As a quick start, one should set their account number. The default location
of this file is `/etc/mullvad-netns/account`. This file must not be readable
by anyone other than root.

```text
Usage:
  mullvad-netns [options] -- <command>
  mullvad-netns <command>

Run <command> under a network namespace connected to a randomly selected
Mullvad server over WireGuard as the only visible network device. This
ensures that the command does not have access to the network except through
the Mullvad tunnel.

Options
  -C, --country <regex>      use only servers from countries matching the
                               given regular expression
  -c, --city <regex>         use only servers from cities matching the
                               given regular expression

  -4, --ipv4                 connect to the Mullvad server over IPv4 (the default)
  -6, --ipv6                 connect to the Mullvad server over IPv6

  -h, --help                 display this help
```

When `--country` is given without `--city`, servers from any city in the
matching countries are used. Otherwise the `CITY` from the configuration
applies.

## DNS

Changing the network namespace is not enough to keep name lookups inside the
tunnel. With the default `nsswitch.conf` of many distributions, lookups go to
`systemd-resolved` (or avahi for `.local` names) over a unix socket, which
resolves them outside of the namespace.

So the command runs in a private mount namespace that has its own
`resolv.conf` and `nsswitch.conf` bind mounted over the ones in `/etc`:

- `resolv.conf` lists the `NAMESERVERS` from the configuration, by default
  only Mullvad's resolver inside the tunnel (`10.64.0.1`)
- `nsswitch.conf` is the system one with the `hosts` line replaced by
  `NSSWITCH_HOSTS` (`files myhostname dns`)

Programs can still reach services outside of the namespace through unix
sockets, such as D-Bus. If `nscd` is running with its hosts cache enabled,
lookups go through it and leave the tunnel, so disable that cache.
