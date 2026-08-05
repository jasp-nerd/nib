SHELL := /bin/bash
.DEFAULT_GOAL := help

PACKAGES := NibCore NibHTTP NibStore NibInterchange NibUI

# --- Toolchain -----------------------------------------------------------------
#
# Full Xcode provides `import Testing` with no flags. This repo also has to build on a
# machine with only Command Line Tools, where Testing.framework ships but SwiftPM does not
# wire it up: the framework lives in one directory and its lib_TestingInterop.dylib in
# another, and neither is on the default search or runtime path. The four flags below
# supply both, and are a no-op under full Xcode.
#
# XCTest is genuinely Xcode-only, hence --disable-xctest. That is fine: everything except
# the launch-time metric test is Swift Testing. Once Xcode is installed, `make test`
# still works unchanged.
CLT_DEV  := /Library/Developer/CommandLineTools/Library/Developer
CLT_FW   := $(CLT_DEV)/Frameworks
CLT_LIB  := $(CLT_DEV)/usr/lib

HAS_XCODE := $(shell xcode-select -p 2>/dev/null | grep -q "Xcode.app" && echo yes || echo no)

# `--enable-swift-testing` is passed in both cases, not only under Command Line Tools. Whether a
# bare `swift test` links the Testing framework depends on the toolchain, and when it does not the
# failure is a wall of undefined Testing symbols at link time rather than anything that names the
# real problem. CI hit exactly that: everything compiled, then the test binary would not link.
# Asking for it explicitly costs nothing where it is already the default.
ifeq ($(HAS_XCODE),no)
# Command Line Tools ships Testing.framework but does not wire up the search paths, so they have to
# be supplied by hand — including the rpath to usr/lib for lib_TestingInterop.dylib.
TEST_FLAGS := --disable-xctest --enable-swift-testing \
              -Xswiftc -F -Xswiftc $(CLT_FW) \
              -Xlinker -F -Xlinker $(CLT_FW) \
              -Xlinker -rpath -Xlinker $(CLT_FW) \
              -Xlinker -rpath -Xlinker $(CLT_LIB)
else
TEST_FLAGS := --enable-swift-testing
endif

# --- Targets -------------------------------------------------------------------

.PHONY: help
help:
	@echo "make build      - build every package"
	@echo "make refresh    - touch sources so SwiftPM notices new files"
	@echo "make test       - run every package's tests"
	@echo "make check      - boundaries + lint + test + size  (what CI runs)"
	@echo ""
	@echo "make app        - assemble dist/Nib.app (debug)"
	@echo "make release    - assemble dist/Nib.app (release, stripped)"
	@echo "make run        - build and launch the app"
	@echo "make measure    - launch-time samples + dyld breakdown"
	@echo "make memory     - physical footprint against the budget"
	@echo "make size       - bundle size against the budget"
	@echo ""
	@echo "make format     - rewrite sources with swift-format"
	@echo "make lint       - swift-format lint + swiftlint"
	@echo "make boundaries - module boundaries and the no-Timer rule"
	@echo "make gen        - regenerate Nib.xcodeproj (needs Xcode)"
	@echo "make doctor     - what the local toolchain can and cannot do"
	@echo "make clean      - remove build artifacts"

# SwiftPM caches each target's source list and does not always notice a *newly created* file --
# the build then fails with "cannot find type X in scope" for a type that plainly exists. Touching
# the sources first costs nothing and removes a genuinely baffling failure mode.
.PHONY: refresh
refresh:
	@find App Packages -name '*.swift' -not -path '*/.build/*' -exec touch {} +

.PHONY: build
build: refresh
	@set -e; for p in $(PACKAGES); do \
		echo "==> building $$p"; \
		swift build --package-path Packages/$$p; \
	done

.PHONY: test
test: refresh
	@set -e; for p in $(PACKAGES); do \
		if [ -n "$$(find Packages/$$p/Tests -name '*.swift' 2>/dev/null)" ]; then \
			echo "==> testing $$p"; \
			swift test --package-path Packages/$$p $(TEST_FLAGS); \
		else \
			echo "==> skipping $$p (no tests yet)"; \
		fi; \
	done

.PHONY: app
app:
	@./Tools/build-app.sh

.PHONY: release
release:
	@./Tools/build-app.sh --release

.PHONY: run
run: app
	@open dist/Nib.app

.PHONY: measure
measure: release
	@./Tools/measure-launch.sh 5

.PHONY: memory
memory: release
	@./Tools/measure-memory.sh

.PHONY: size
size: release
	@./Tools/check-size.sh

.PHONY: boundaries
boundaries:
	@./Tools/check-boundaries.sh

.PHONY: format
format:
	@xcrun swift-format format --in-place --recursive App Packages

.PHONY: lint
lint:
	@xcrun swift-format lint --strict --recursive App Packages
# swiftlint links against sourcekitdInProc.framework, which ships only with full Xcode -- under
# Command Line Tools it hard-crashes rather than degrading, so it is gated on Xcode being
# present. CI always has Xcode, so the rules are always enforced there.
ifeq ($(HAS_XCODE),yes)
# Two separate statements on purpose. Writing `swiftlint || echo "not installed"` swallows real
# lint failures AND reports a misleading reason -- the gate silently stops gating.
	@command -v swiftlint >/dev/null || { echo "swiftlint missing - brew install swiftlint"; exit 1; }
	@swiftlint --strict --quiet
else
	@echo "swiftlint: skipped (needs full Xcode for sourcekitd; enforced in CI)"
endif

.PHONY: check
check: boundaries lint test size

.PHONY: gen
gen:
	@command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
	@xcodegen generate

.PHONY: doctor
doctor:
	@echo "swift        : $$(swift --version 2>&1 | head -1)"
	@echo "developer dir: $$(xcode-select -p)"
	@echo "full Xcode   : $(HAS_XCODE)"
	@echo "xcodegen     : $$(command -v xcodegen >/dev/null && xcodegen --version || echo 'MISSING (brew install xcodegen)')"
	@echo "swift-format : $$(xcrun --find swift-format 2>/dev/null || echo MISSING)"
	@echo
ifeq ($(HAS_XCODE),no)
	@echo "Command Line Tools only -- but almost everything works:"
	@echo "  build + test all packages, assemble and run dist/Nib.app,"
	@echo "  measure launch time, enforce the size gate, generate the xcodeproj."
	@echo ""
	@echo "Still needs full Xcode:"
	@echo "  - actool (asset catalogs / app icon)  -> bites at Phase 8"
	@echo "  - Instruments (pre-main dyld split, memory graph)"
	@echo "  - XCTest (XCTApplicationLaunchMetric regression test)"
	@echo "  - notarization"
endif

.PHONY: clean
clean:
	@for p in $(PACKAGES); do rm -rf Packages/$$p/.build; done
	@rm -rf .build build Nib.xcodeproj
