# Deployed by Ansible to ~/fail2ban/Makefile (playbooks/fail2ban role; connection user’s home).
# On host: cd ~/fail2ban && make help
# Override if needed: make F2B="sudo fail2ban-client -c /etc/fail2ban" unban-all
F2B ?= sudo fail2ban-client

.DEFAULT_GOAL := help

.PHONY: help status list-bans unban-all unban-all-loop

help:
	@echo "fail2ban — manual mass unban (clears bans; jails stay enabled)"
	@echo ""
	@echo "  make unban-all        fastest: unban every IP from every jail"
	@echo "  make unban-all-loop   same outcome, per-jail unbanip (older fail2ban)"
	@echo "  make list-bans        show banned counts / IPs per jail"
	@echo "  make status           fail2ban-client status"
	@echo ""
	@echo "F2B=$(F2B)"

status:
	$(F2B) status

list-bans:
	@set -euf; \
	jails_raw=$$($(F2B) status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | head -1); \
	if [ -z "$$jails_raw" ]; then echo "no jails (is fail2ban running?)"; exit 1; fi; \
	IFS=','; \
	for jail in $$jails_raw; do \
	  jail=$$(echo "$$jail" | sed 's/^[[:space:]]*//;s/[[:space:]]*$$//'); \
	  [ -n "$$jail" ] || continue; \
	  echo "=== $$jail ==="; \
	  $(F2B) status "$$jail" 2>/dev/null | grep -E 'Currently banned|Banned IP list' || true; \
	done

# Requires fail2ban >= 0.10.4 (unban --all).
unban-all:
	$(F2B) unban --all

# No --all: walk each jail and unban each IP (idempotent if nothing banned).
unban-all-loop:
	@set -euf; \
	jails_raw=$$($(F2B) status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | head -1); \
	if [ -z "$$jails_raw" ]; then echo "no jails (is fail2ban running?)"; exit 1; fi; \
	IFS=','; \
	for jail in $$jails_raw; do \
	  jail=$$(echo "$$jail" | sed 's/^[[:space:]]*//;s/[[:space:]]*$$//'); \
	  [ -n "$$jail" ] || continue; \
	  ips=$$($(F2B) status "$$jail" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p' | head -1); \
	  for ip in $$ips; do \
	    [ -n "$$ip" ] || continue; \
	    echo "$(F2B) set $$jail unbanip $$ip"; \
	    $(F2B) set "$$jail" unbanip "$$ip"; \
	  done; \
	done; \
	echo "done"
