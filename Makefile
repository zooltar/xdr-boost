PREFIX ?= /usr/local
BINARY = xdr-boost
BUILD_DIR = .build

APP_NAME = XDR Boost
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app

LAUNCH_AGENT_USER = $(if $(SUDO_USER),$(SUDO_USER),$(USER))
LAUNCH_AGENT_UID = $(shell id -u "$(LAUNCH_AGENT_USER)")
LAUNCH_AGENT_GROUP = $(shell id -gn "$(LAUNCH_AGENT_USER)")
LAUNCH_AGENT_HOME = $(if $(SUDO_USER),$(shell dscl . -read "/Users/$(SUDO_USER)" NFSHomeDirectory | awk '{print $$2}'),$(HOME))
LAUNCH_AGENT_DIR = $(LAUNCH_AGENT_HOME)/Library/LaunchAgents
LAUNCH_AGENT_PLIST = $(LAUNCH_AGENT_DIR)/com.xdr-boost.agent.plist

.PHONY: build test install uninstall clean launch-agent remove-agent app dmg
.PHONY: rebuild

build:
	@mkdir -p $(BUILD_DIR)
	swiftc -O -o $(BUILD_DIR)/$(BINARY) Sources/*.swift \
		-framework Cocoa -framework MetalKit -framework Metal -framework ColorSync

test:
	@mkdir -p $(BUILD_DIR)
	swiftc -warnings-as-errors -parse-as-library \
		-o $(BUILD_DIR)/boost-level-settings-tests \
		Sources/BoostLevelSettings.swift Tests/BoostLevelSettingsTests.swift
	$(BUILD_DIR)/boost-level-settings-tests

install: build
	install -d $(PREFIX)/bin
	install -m 755 $(BUILD_DIR)/$(BINARY) $(PREFIX)/bin/$(BINARY)

uninstall: remove-agent
	rm -f $(PREFIX)/bin/$(BINARY)

# Install LaunchAgent to start on login
launch-agent: install
	@install -d -o "$(LAUNCH_AGENT_USER)" -g "$(LAUNCH_AGENT_GROUP)" "$(LAUNCH_AGENT_DIR)"
	@sed "s|__BINARY__|$(PREFIX)/bin/$(BINARY)|g" \
		com.xdr-boost.agent.plist > "$(LAUNCH_AGENT_PLIST)"
	@chown "$(LAUNCH_AGENT_USER):$(LAUNCH_AGENT_GROUP)" "$(LAUNCH_AGENT_PLIST)"
	-@launchctl bootout "gui/$(LAUNCH_AGENT_UID)" "$(LAUNCH_AGENT_PLIST)" 2>/dev/null
	launchctl bootstrap "gui/$(LAUNCH_AGENT_UID)" "$(LAUNCH_AGENT_PLIST)"
	@echo "xdr-boost will now start on login"

remove-agent:
	-@launchctl bootout "gui/$(LAUNCH_AGENT_UID)" "$(LAUNCH_AGENT_PLIST)" 2>/dev/null
	rm -f "$(LAUNCH_AGENT_PLIST)"

app: build
	@mkdir -p "$(APP_BUNDLE)/Contents/MacOS"
	@mkdir -p "$(APP_BUNDLE)/Contents/Resources"
	@cp $(BUILD_DIR)/$(BINARY) "$(APP_BUNDLE)/Contents/MacOS/$(BINARY)"
	@cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	@cp AppIcon.icns "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"
	@codesign --force --sign - "$(APP_BUNDLE)"
	@echo "Built $(APP_BUNDLE)"

dmg: app
	@rm -rf "$(BUILD_DIR)/dmg"
	@mkdir -p "$(BUILD_DIR)/dmg"
	@cp -R "$(APP_BUNDLE)" "$(BUILD_DIR)/dmg/"
	@ln -s /Applications "$(BUILD_DIR)/dmg/Applications"
	@hdiutil create -volname "XDR Boost" -srcfolder "$(BUILD_DIR)/dmg" \
		-ov -format UDZO "$(BUILD_DIR)/XDR-Boost.dmg"
	@rm -rf "$(BUILD_DIR)/dmg"
	@echo "Built $(BUILD_DIR)/XDR-Boost.dmg"

clean:
	rm -rf $(BUILD_DIR)

rebuild:
	@if [ "$$(id -u)" -ne 0 ] || [ -z "$(SUDO_USER)" ]; then \
		echo "Run 'sudo make rebuild'"; \
		exit 1; \
	fi
	@set -e; \
		trap 'chown -R "$(LAUNCH_AGENT_USER):$(LAUNCH_AGENT_GROUP)" "$(BUILD_DIR)" 2>/dev/null || true' EXIT; \
		$(MAKE) clean; \
		$(MAKE) dmg; \
		$(MAKE) launch-agent
