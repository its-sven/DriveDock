# Convenience targets – the real work happens in scripts/.
.PHONY: app install release icon signing clean

app:            ## Build build/DriveDock.app for this Mac
	scripts/build-app.sh

install:        ## Build, copy to ~/Applications and launch
	scripts/build-app.sh --install

release:        ## Universal build + DMG + ZIP in dist/
	scripts/package.sh

icon:           ## Re-render Resources/AppIcon.icns and docs/icon.png
	swift scripts/make-icon.swift Resources/AppIcon.icns docs/icon.png

signing:        ## One-time: local signing identity (no keychain prompts after updates)
	scripts/setup-signing.sh

clean:
	rm -rf .build build dist
