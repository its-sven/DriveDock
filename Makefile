# Convenience targets – the real work happens in scripts/.
.PHONY: app install release icon signing check clean

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

clean:
	rm -rf .build build dist
