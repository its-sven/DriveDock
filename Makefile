# Convenience targets – the real work happens in scripts/.
.PHONY: app install release icon signing check test screenshots demo clean

app:            ## Build build/DriveDock.app for this Mac
	scripts/build-app.sh

install:        ## Build, copy to ~/Applications and launch
	scripts/build-app.sh --install

release:        ## Universal build + DMG + ZIP in dist/
	scripts/package.sh

icon:           ## Re-render Resources/AppIcon.icns and docs/icon.png
	swift scripts/make-icon.swift Resources/AppIcon.icns docs/icon.png

signing:        ## One-time: local signing identity (stable code identity across builds)
	scripts/setup-signing.sh

check:          ## Verify that every UI text has a translation
	scripts/check-localization.py

test:           ## Run the unit tests
	swift test

demo: app       ## Open DriveDock with made-up servers (mounts nothing)
	open -n build/DriveDock.app --args --demo -AppleLanguages '(en)' -mountRootName "Network Drives"

screenshots: app ## Re-capture docs/images (light + dark) and the banner from the demo
	scripts/make-screenshots.sh

clean:
	rm -rf .build build dist
