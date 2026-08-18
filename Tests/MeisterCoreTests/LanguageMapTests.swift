import Testing
@testable import MeisterCore

@Suite
struct LanguageMapTests {
    @Test
    func mapsKnownExtensions() {
        let cases: [(String, Language)] = [
            ("Sources/App.swift", .swift),
            ("src/main.ts", .typescript),
            ("src/App.tsx", .typescript),
            ("lib/index.js", .javascript),
            ("lib/x.jsx", .javascript),
            ("lib/mod.mjs", .javascript),
            ("lib/mod.cjs", .javascript),
            ("app.py", .python),
            ("types.pyi", .python),
            ("main.go", .go),
            ("src/lib.rs", .rust),
            ("Main.java", .jvm),
            ("Main.kt", .jvm),
            ("build.kts", .jvm),
            ("foo.c", .c),
            ("foo.h", .c),
            ("foo.cc", .c),
            ("foo.cpp", .c),
            ("foo.hpp", .c),
            ("app.rb", .ruby),
            ("Program.cs", .csharp),
            ("setup.sh", .shell),
            ("setup.bash", .shell),
            ("setup.zsh", .shell),
            ("ci.yml", .yaml),
            ("ci.yaml", .yaml),
            ("package.json", .json),
            ("README.md", .markdown),
            ("unknown.bin", .other),
            ("Makefile", .other),
        ]
        for (path, language) in cases {
            #expect(LanguageMap.language(forPath: path) == language)
        }
    }
}
