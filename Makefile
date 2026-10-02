NAME = mullvad-netns

PREFIX ?= usr
BINDIR ?= usr/bin
SYSCONFDIR ?= etc
FISHCOMPDIR ?= $(PREFIX)/share/fish/vendor_completions.d
INSTALL = install
# packages that set the capability at install time instead can use SETCAP=:
SETCAP ?= setcap

CFLAGS ?= -O2 -g
CFLAGS += -Wall -Wextra

.PHONY: all clean install

all: $(NAME)-exec

$(NAME)-exec: $(NAME)-exec.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)

install: $(NAME).bash $(NAME)-exec rules.nft
	$(INSTALL) -D mullvad-netns.bash $(DESTDIR)/$(BINDIR)/$(NAME)
	$(INSTALL) -D $(NAME)-exec $(DESTDIR)/$(BINDIR)/$(NAME)-exec
	$(SETCAP) cap_sys_admin=ep $(DESTDIR)/$(BINDIR)/$(NAME)-exec
	$(INSTALL) -m 0644 -D $(NAME).fish $(DESTDIR)/$(FISHCOMPDIR)/$(NAME).fish
	$(INSTALL) -m 0644 -D rules.nft $(DESTDIR)/$(SYSCONFDIR)/$(NAME)/rules.nft
	$(INSTALL) -m 0644 $(NAME).config $(DESTDIR)/$(SYSCONFDIR)/$(NAME)/config
	$(INSTALL) -m 0600 account $(DESTDIR)/$(SYSCONFDIR)/$(NAME)/account

clean:
	rm -f $(NAME)-exec
