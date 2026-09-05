.PHONY: build test verify test-helper test-runtime app install run signing-identity reset-permission unquarantine notarize clean

build:
	swift build

test:
	swift run LayoutEngineChecks
	sh Scripts/test-app.sh

verify:
	sh Scripts/verify-release-metadata.sh
	swift build
	swift run LayoutEngineChecks
	sh Scripts/test-app.sh

# Launches a real group companion and verifies the Command-Tab handshake.
# Needs `make app` first.
test-helper: app
	swift build --product GroupHostIntegrationChecks
	sh Scripts/test-helper.sh "/private/tmp/Window Columns.app/Contents/Helpers/Window Group 9.app"

# End-to-end checks against the installed, running app and the real window
# server: activation, column geometry, companion lifecycle, group identity.
# Needs the app installed and running, and Accessibility granted.
test-runtime:
	swift run RuntimeGroupChecks

app:
	sh Scripts/build-app.sh

# Accessibility is granted per bundle path, so the app runs from /Applications.
install:
	INSTALL=1 sh Scripts/build-app.sh

run: install
	open "/Applications/Window Columns.app"

# Creates a stable local signing identity so the Accessibility grant given to
# Window Columns survives every rebuild. Run once.
signing-identity:
	sh Scripts/create-signing-identity.sh

# Clears stale Accessibility grants, including phantom entries left by earlier
# ad-hoc builds that still show as enabled but no longer match the app.
reset-permission:
	tccutil reset Accessibility com.adimaskil.WindowColumns || true
	@echo "Cleared. Launch the app and grant Accessibility again."

# Removes Gatekeeper quarantine attributes from the installed application bundle.
unquarantine:
	xattr -dr com.apple.quarantine "/Applications/Window Columns.app" || true
	@echo "Cleared Gatekeeper quarantine from /Applications/Window Columns.app"

# Notarizes the app bundle with Apple's Notary service and staples the ticket.
notarize:
	sh Scripts/notarize.sh

clean:
	swift package clean
