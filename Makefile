# Makefile for zag
# Wraps zig build with convenience targets and release artifact generation.

VERSION      := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
ZIG          := zig
BUILD_DIR    := zig-out/bin
DIST_DIR     := dist
ARTIFACT_DIR := artifacts

TARGETS := \
	x86_64-linux-musl \
	aarch64-linux-musl \
	x86_64-macos \
	aarch64-macos

.DEFAULT_GOAL := build

# ---------------------------------------------------------------------------
# Development
# ---------------------------------------------------------------------------

.PHONY: build
build:
	$(ZIG) build

.PHONY: run
run:
	$(ZIG) build run

.PHONY: test
test:
	$(ZIG) build test

.PHONY: fmt-check
fmt-check:
	$(ZIG) fmt --check build.zig build.zig.zon src

.PHONY: fmt
fmt:
	$(ZIG) fmt build.zig build.zig.zon src

# ---------------------------------------------------------------------------
# Release builds (cross-compilation)
# ---------------------------------------------------------------------------

.PHONY: release
release: $(addprefix release-,$(TARGETS))

.PHONY: $(addprefix release-,$(TARGETS))
$(addprefix release-,$(TARGETS)): release-%:
	$(ZIG) build -Dtarget=$* -Doptimize=ReleaseSafe -Dsim=false

# ---------------------------------------------------------------------------
# Artifacts (tar.gz + checksums, matching CI release workflow)
# ---------------------------------------------------------------------------

.PHONY: package
package: $(addprefix package-,$(TARGETS))

.PHONY: $(addprefix package-,$(TARGETS))
$(addprefix package-,$(TARGETS)): package-%: release-%
	@mkdir -p $(ARTIFACT_DIR)
	@rm -rf $(DIST_DIR)
	@mkdir -p $(DIST_DIR)
	cp $(BUILD_DIR)/zag $(DIST_DIR)/
	cp README.md $(DIST_DIR)/ 2>/dev/null || true
	cp LICENSE $(DIST_DIR)/ 2>/dev/null || true
	tar czf $(ARTIFACT_DIR)/zag-$(VERSION)-$*.tar.gz -C $(DIST_DIR) .
	@rm -rf $(DIST_DIR)
	@echo "Created $(ARTIFACT_DIR)/zag-$(VERSION)-$*.tar.gz"

.PHONY: checksums
checksums:
	@cd $(ARTIFACT_DIR) && sha256sum zag-*.tar.gz > checksums.txt
	@echo "Created $(ARTIFACT_DIR)/checksums.txt"

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

.PHONY: clean
clean:
	$(ZIG) build --help >/dev/null 2>&1 && $(ZIG) build uninstall 2>/dev/null || true
	rm -rf zig-out .zig-cache $(DIST_DIR) $(ARTIFACT_DIR)
