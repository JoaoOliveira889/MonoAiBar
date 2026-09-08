.PHONY: all build bundle run install clean

all: bundle

clean:
	@echo "==> Cleaning builds and artifacts from previous versions..."
	@pkill -x MonoAiBar 2>/dev/null || true
	@pkill -x MonoBar 2>/dev/null || true
	@rm -rf .build MonoBar.app MonoAiBar.app
	@echo "==> Cleanup complete."

build:
	@./scripts/build.sh

bundle:
	@./scripts/bundle.sh

run:
	@./scripts/run.sh

install: clean bundle
	@echo "==> Performing clean atomic installation of MonoAiBar..."
	@pkill -x MonoAiBar 2>/dev/null || true
	@pkill -x MonoBar 2>/dev/null || true
	@rm -rf /Applications/MonoBar.app ~/Applications/MonoBar.app /Applications/MonoAiBar.app ~/Applications/MonoAiBar.app
	@cp -R MonoAiBar.app /Applications/
	@cp -R MonoAiBar.app ~/Applications/
	@mkdir -p ~/.local/bin
	@rm -f ~/.local/bin/monobar ~/.local/bin/monoaibar
	@ln -sf "/Applications/MonoAiBar.app/Contents/MacOS/MonoAiBar" ~/.local/bin/monoaibar
	@ln -sf "/Applications/MonoAiBar.app/Contents/MacOS/MonoAiBar" ~/.local/bin/monobar
	@echo "==> Refreshing macOS system caches (LaunchServices, QuickLook, Finder)..."
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MonoAiBar.app
	@qlmanage -r 2>/dev/null || true
	@killall Finder 2>/dev/null || true
	@touch /Applications/MonoAiBar.app
	@echo "==> MonoAiBar cleanly installed!"
	@echo "    • App: /Applications/MonoAiBar.app"
	@echo "    • CLI: ~/.local/bin/monoaibar"
