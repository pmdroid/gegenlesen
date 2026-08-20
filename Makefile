.PHONY: build test run docs image clean release-darwin

export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

build:
	./scripts/swift build

test:
	./scripts/swift test

run:
	./scripts/dev.sh

docs:
	cd www && npm run dev -- --host 0.0.0.0 --port 4321

image:
	./scripts/build-image.sh

# Mac GitHub artifacts. Example: make release-darwin VERSION=v0.1.0 ARGS='--upload'
release-darwin:
	@test -n "$(VERSION)" || (echo "usage: make release-darwin VERSION=v0.1.0 [ARGS='--upload']" >&2; exit 1)
	./scripts/release-darwin.sh $(VERSION) $(ARGS)

clean:
	rm -rf .build
