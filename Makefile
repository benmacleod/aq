.PHONY: install install-swiftbar test

# Links bin/* into ~/.local/bin. Agents' hooks call the adapters there.
install:
	brew bundle
	@mkdir -p $(HOME)/.local/bin
	@for script in $(CURDIR)/bin/*; do \
		target=$(HOME)/.local/bin/$$(basename $$script); \
		if [ ! -e "$$target" ] && [ ! -L "$$target" ]; then \
			ln -s "$$script" "$$target" && echo "Linked $$target"; \
		else \
			echo "Skipping $$target (already exists)"; \
		fi; \
	done
	@$(MAKE) --no-print-directory install-swiftbar

# SwiftBar stores its plugin folder once you've chosen one on first launch.
install-swiftbar:
	@dir=$$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null); \
	if [ -z "$$dir" ]; then \
		echo "Skipping the SwiftBar plugin: open SwiftBar, choose a plugin folder, then run make install-swiftbar"; \
		exit 0; \
	fi; \
	for plugin in $(CURDIR)/swiftbar/*; do \
		target="$$dir/$$(basename $$plugin)"; \
		if [ ! -e "$$target" ] && [ ! -L "$$target" ]; then \
			ln -s "$$plugin" "$$target" && echo "Linked $$target"; \
		else \
			echo "Skipping $$target (already exists)"; \
		fi; \
	done

test:
	bats test/
