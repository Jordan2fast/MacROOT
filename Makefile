# Convenience targets. Building needs macOS with Xcode 16+.
.PHONY: build pkg embed check clean

build:
	xcodebuild -project MacROOT.xcodeproj -scheme MacROOT -configuration Release \
		-arch x86_64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO build

pkg:
	./Packaging/build_installer.sh

# Regenerate MacROOT/Core/MacROOTScript.swift after editing Scripts/macROOT.sh
embed:
	python3 Scripts/embed_script.py

# What CI runs on Linux: shell syntax + "embedded script is current"
check:
	bash -n Scripts/macROOT.sh
	bash -n Scripts/iservices-helper.sh
	bash -n Packaging/build_installer.sh
	bash -n Packaging/scripts/postinstall
	python3 Scripts/embed_script.py
	git diff --exit-code MacROOT/Core/MacROOTScript.swift

clean:
	rm -rf build MacROOT-Installer.pkg
