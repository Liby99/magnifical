// Lightweight code-fence syntax highlighting for the markdown preview — the house languages
// (c, c++, rust, python, js, ts, ocaml, lean, haskell, java, julia), one generic tokenizer:
// comments (line + block per language), strings/chars, numbers, and per-language keyword sets.
// System semantic colors, so dark/light adapt for free.

import AppKit

enum CodeHighlight {
    struct Lang {
        let keywords: Set<String>
        let lineComments: [String]
        let blockComments: [(String, String)]
        var preprocessor = false // '#…' directives at line start (c/c++)
        var decorators = false // '@name' (py/java/ts) / '#[…]'-adjacent attribute style
    }

    private static let cKeywords: Set<String> = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
        "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register",
        "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
        "unsigned", "void", "volatile", "while", "NULL", "true", "false", "bool",
    ]

    private static let langs: [String: Lang] = {
        let cLike = [("/*", "*/")]
        var m: [String: Lang] = [:]
        m["c"] = Lang(keywords: cKeywords, lineComments: ["//"], blockComments: cLike,
                      preprocessor: true)
        m["cpp"] = Lang(
            keywords: cKeywords.union([
                "class", "namespace", "template", "typename", "public", "private", "protected",
                "virtual", "override", "new", "delete", "this", "nullptr", "constexpr", "auto",
                "using", "try", "catch", "throw", "operator", "friend", "explicit", "mutable",
                "static_cast", "dynamic_cast", "reinterpret_cast", "const_cast", "noexcept",
            ]),
            lineComments: ["//"], blockComments: cLike, preprocessor: true
        )
        m["rust"] = Lang(
            keywords: [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
                "super", "trait", "type", "unsafe", "use", "where", "while", "true", "false",
                "Some", "None", "Ok", "Err",
            ],
            lineComments: ["//"], blockComments: cLike
        )
        m["python"] = Lang(
            keywords: [
                "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
                "return", "try", "while", "with", "yield", "True", "False", "None", "self",
            ],
            lineComments: ["#"], blockComments: [], decorators: true
        )
        m["js"] = Lang(
            keywords: [
                "async", "await", "break", "case", "catch", "class", "const", "continue",
                "debugger", "default", "delete", "do", "else", "export", "extends", "finally",
                "for", "function", "if", "import", "in", "instanceof", "let", "new", "of",
                "return", "static", "super", "switch", "this", "throw", "try", "typeof", "var",
                "void", "while", "with", "yield", "true", "false", "null", "undefined",
            ],
            lineComments: ["//"], blockComments: cLike
        )
        m["ts"] = Lang(
            keywords: m["js"]!.keywords.union([
                "interface", "type", "enum", "implements", "namespace", "declare", "readonly",
                "public", "private", "protected", "abstract", "as", "is", "keyof", "infer",
                "never", "unknown", "any", "string", "number", "boolean", "object", "symbol",
            ]),
            lineComments: ["//"], blockComments: cLike, decorators: true
        )
        m["ocaml"] = Lang(
            keywords: [
                "and", "as", "assert", "begin", "class", "constraint", "do", "done", "downto",
                "else", "end", "exception", "external", "false", "for", "fun", "function",
                "functor", "if", "in", "include", "inherit", "lazy", "let", "match", "method",
                "module", "mutable", "new", "object", "of", "open", "or", "rec", "sig", "struct",
                "then", "to", "true", "try", "type", "val", "virtual", "when", "while", "with",
            ],
            lineComments: [], blockComments: [("(*", "*)")]
        )
        m["lean"] = Lang(
            keywords: [
                "def", "theorem", "lemma", "example", "axiom", "inductive", "structure", "class",
                "instance", "where", "match", "with", "fun", "λ", "let", "in", "do", "by",
                "have", "show", "from", "calc", "sorry", "namespace", "open", "section", "end",
                "variable", "universe", "import", "if", "then", "else", "mutual", "partial",
                "noncomputable", "abbrev", "deriving", "extends", "return",
            ],
            lineComments: ["--"], blockComments: [("/-", "-/")]
        )
        m["haskell"] = Lang(
            keywords: [
                "case", "class", "data", "default", "deriving", "do", "else", "foreign", "if",
                "import", "in", "infix", "infixl", "infixr", "instance", "let", "module",
                "newtype", "of", "then", "type", "where", "qualified", "as", "hiding",
            ],
            lineComments: ["--"], blockComments: [("{-", "-}")]
        )
        m["java"] = Lang(
            keywords: [
                "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char",
                "class", "const", "continue", "default", "do", "double", "else", "enum",
                "extends", "final", "finally", "float", "for", "if", "implements", "import",
                "instanceof", "int", "interface", "long", "native", "new", "package", "private",
                "protected", "public", "return", "short", "static", "strictfp", "super",
                "switch", "synchronized", "this", "throw", "throws", "transient", "try", "var",
                "void", "volatile", "while", "true", "false", "null", "record", "sealed",
            ],
            lineComments: ["//"], blockComments: cLike, decorators: true
        )
        m["julia"] = Lang(
            keywords: [
                "abstract", "baremodule", "begin", "break", "catch", "const", "continue", "do",
                "else", "elseif", "end", "export", "finally", "for", "function", "global", "if",
                "import", "in", "let", "local", "macro", "module", "mutable", "primitive",
                "quote", "return", "struct", "try", "type", "using", "while", "true", "false",
                "nothing", "missing",
            ],
            lineComments: ["#"], blockComments: [("#=", "=#")], decorators: true
        )
        // Aliases
        m["c++"] = m["cpp"]; m["cxx"] = m["cpp"]; m["cc"] = m["cpp"]; m["h"] = m["c"]
        m["rs"] = m["rust"]
        m["py"] = m["python"]; m["python3"] = m["python"]
        m["javascript"] = m["js"]; m["jsx"] = m["js"]
        m["typescript"] = m["ts"]; m["tsx"] = m["ts"]
        m["ml"] = m["ocaml"]
        m["hs"] = m["haskell"]
        m["jl"] = m["julia"]
        m["lean4"] = m["lean"]
        return m
    }()

    /// Highlight `code` for `lang` (empty/unknown → plain mono). Colors are system semantic
    /// hues so both appearances read well: keywords purple, strings red-brown, numbers teal,
    /// comments dimmed oblique.
    static func highlight(_ code: String, lang: String, base: NSColor, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: code, attributes: [.font: font, .foregroundColor: base.withAlphaComponent(0.88)]
        )
        guard let l = langs[lang.lowercased()] else { return out }
        let ns = code as NSString
        let keywordColor = NSColor.systemPurple
        let stringColor = NSColor.systemBrown
        let numberColor = NSColor.systemTeal
        let typeColor = NSColor.systemIndigo
        let callColor = NSColor.systemBlue
        let commentColor = base.withAlphaComponent(0.42)

        var i = 0
        var bol = true // at line start (only whitespace so far) — for #directives
        while i < ns.length {
            let ch = ns.character(at: i)
            let c = Character(UnicodeScalar(ch) ?? " ")
            if c == "\n" {
                bol = true; i += 1; continue
            }
            defer {
                if !c.isWhitespace {
                    bol = false
                }
            }
            // c/c++ preprocessor: '#include', '#define', … to end of line
            if l.preprocessor, bol, c == "#" {
                let nl = ns.range(of: "\n", range: NSRange(location: i, length: ns.length - i))
                let stop = nl.location == NSNotFound ? ns.length : nl.location
                out.addAttribute(.foregroundColor, value: callColor,
                                 range: NSRange(location: i, length: stop - i))
                i = stop
                continue
            }
            // decorators / macros: @Something (py/java/ts/julia's @macro)
            if l.decorators, c == "@", i + 1 < ns.length,
               Character(UnicodeScalar(ns.character(at: i + 1)) ?? " ").isLetter {
                var j = i + 1
                while j < ns.length {
                    let cj = Character(UnicodeScalar(ns.character(at: j)) ?? " ")
                    if cj.isLetter || cj.isNumber || cj == "_" || cj == "." {
                        j += 1
                    } else {
                        break
                    }
                }
                out.addAttribute(.foregroundColor, value: callColor,
                                 range: NSRange(location: i, length: j - i))
                i = j
                continue
            }
            // Block comments
            if let bc = l.blockComments.first(where: { matches(ns, at: i, $0.0) }) {
                let end = ns.range(of: bc.1, range: NSRange(location: i, length: ns.length - i))
                let stop = end.location == NSNotFound ? ns.length : NSMaxRange(end)
                out.addAttributes([.foregroundColor: commentColor, .obliqueness: 0.12],
                                  range: NSRange(location: i, length: stop - i))
                i = stop
                continue
            }
            // Line comments
            if let lc = l.lineComments.first(where: { matches(ns, at: i, $0) }) {
                _ = lc
                let nl = ns.range(of: "\n", range: NSRange(location: i, length: ns.length - i))
                let stop = nl.location == NSNotFound ? ns.length : nl.location
                out.addAttributes([.foregroundColor: commentColor, .obliqueness: 0.12],
                                  range: NSRange(location: i, length: stop - i))
                i = stop
                continue
            }
            // Strings / chars
            if ch == 0x22 || ch == 0x27 { // " or '
                let quote = ch
                var j = i + 1
                while j < ns.length {
                    let cj = ns.character(at: j)
                    if cj == 0x5C {
                        j += 2; continue
                    } // backslash escape
                    if cj == quote || cj == 0x0A {
                        break
                    }
                    j += 1
                }
                let stop = min(j + 1, ns.length)
                out.addAttribute(.foregroundColor, value: stringColor,
                                 range: NSRange(location: i, length: stop - i))
                i = stop
                continue
            }
            // Numbers
            if c.isNumber {
                var j = i + 1
                while j < ns.length {
                    let cj = Character(UnicodeScalar(ns.character(at: j)) ?? " ")
                    if cj.isHexDigit || cj == "." || cj == "x" || cj == "_" || cj == "e" {
                        j += 1
                    } else {
                        break
                    }
                }
                out.addAttribute(.foregroundColor, value: numberColor,
                                 range: NSRange(location: i, length: j - i))
                i = j
                continue
            }
            // Identifiers → keywords
            if c.isLetter || c == "_" {
                var j = i + 1
                while j < ns.length {
                    let cj = Character(UnicodeScalar(ns.character(at: j)) ?? " ")
                    if cj.isLetter || cj.isNumber || cj == "_" {
                        j += 1
                    } else {
                        break
                    }
                }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                let range = NSRange(location: i, length: j - i)
                if l.keywords.contains(word) {
                    out.addAttributes([
                        .foregroundColor: keywordColor,
                        .font: NSFont(name: "Menlo-Bold", size: font.pointSize)
                            ?? .monospacedSystemFont(ofSize: font.pointSize, weight: .semibold),
                    ], range: range)
                } else if c.isUppercase {
                    // Types / constructors / modules (Rust, Haskell, OCaml, Lean, Julia, Java…)
                    out.addAttribute(.foregroundColor, value: typeColor, range: range)
                } else {
                    // A call: identifier directly followed by '('
                    var k = j
                    while k < ns.length, ns.character(at: k) == 0x20 {
                        k += 1
                    }
                    if k < ns.length, ns.character(at: k) == 0x28 {
                        out.addAttribute(.foregroundColor, value: callColor, range: range)
                    }
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    private static func matches(_ ns: NSString, at i: Int, _ token: String) -> Bool {
        let t = token as NSString
        guard i + t.length <= ns.length else { return false }
        return ns.substring(with: NSRange(location: i, length: t.length)) == token
    }
}
