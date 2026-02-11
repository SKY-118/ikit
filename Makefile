install:
	swift build -c release
	install .build/release/ikit ~/.local/bin/ikit
