if exists("b:current_syntax")
  finish
endif

" Syntax for worklog.nvim (.wkl files). The matching mirrors the parser in
" lua/worklog/document.lua so highlighting agrees with how the plugin reads a
" file:
"   * Worklog headers examine every whitespace-separated token.
"   * Entries and summary rows only treat a TRAILING run of #tag / @location /
"     !L tokens as metadata. A '#word' earlier in the text is plain text, so
"     "10:17 #Q1 features" has no tag.
"   * Indented lines are free-form notes.

" Block headers ------------------------------------------------------------
" Generated section headers, e.g. --- summary exact --- or --- tags quantized ---
syntax match WorklogBlockHeader /^---\s.\+\s---$/

" Worklog headers carry sticky metadata and options. Defined after the generic
" header so it wins for the lines it matches.
syntax match WorklogHeader /^--- worklog\s.\{-}---$/
  \ contains=WorklogTag,WorklogOoo,WorklogLocation,WorklogOption

" Entry timestamps: HH:MM at the start of a line.
syntax match WorklogTimestamp /^\d\{2}:\d\{2}/

" Summary rows -------------------------------------------------------------
" Generated rows start at column 0 with a decimal duration; quantized rows add
" a (+Nm) rounding error.
syntax match WorklogDuration /^\d\+\.\d\+h/
syntax match WorklogQuantError /([+-]\d\+m)/

" Trailing metadata --------------------------------------------------------
" document.lua scans tokens from the end of an entry and keeps consuming #tag,
" @location and !L until it reaches ordinary text. This match captures exactly
" that trailing run (for entries and summary rows alike); the tokens inside it
" are highlighted by the contained matches below.
syntax match WorklogMeta
  \ /\%(\s\+\%(#[[:alnum:]_-]\+\|@[[:alnum:]_-]\+\|!L\)\)\+$/
  \ contains=WorklogTag,WorklogOoo,WorklogLocation,WorklogLogged

" Metadata tokens ----------------------------------------------------------
" These are 'contained' so they only highlight inside a worklog header or a
" trailing metadata run, never mid-text. The whitespace lookbehind stops a '#'
" inside a word (foo#bar) from matching. The #-/@- clear tokens fall through to
" the tag/location matches on purpose, so they read like ordinary metadata.
syntax match WorklogTag /\s\@<=#[[:alnum:]_-]\+/ contained

" #ooo is special: it counts toward activity but is excluded from workday.
" Defined after WorklogTag so it wins at #ooo; the lookahead avoids matching
" longer tags like #ooops or #ooo-bar.
syntax match WorklogOoo /\s\@<=#ooo\%([[:alnum:]_-]\)\@!/ contained

syntax match WorklogLocation /\s\@<=@[[:alnum:]_-]\+/ contained

" !L is only valid on entries/summary rows, so it is not in the header's contains.
syntax match WorklogLogged /\s\@<=!L/ contained

" key=value options are only valid in worklog headers.
syntax match WorklogOption /\s\@<=[[:alnum:]_-]\+=[[:alnum:]_-]*/ contained

" Notes --------------------------------------------------------------------
" Free-form text the user indents under an entry or summary item. A region with
" contains=NONE keeps the whole line dimmed, including any stray #/@ tokens, and
" stops the trailing-metadata match from firing inside it.
syntax region WorklogNote start=/^\s\+\S/ end=/$/ contains=NONE keepend

highlight default link WorklogHeader      Title
highlight default link WorklogBlockHeader Comment
highlight default link WorklogTimestamp   Statement
highlight default link WorklogTag         Identifier
highlight default link WorklogOoo         WarningMsg
highlight default link WorklogLocation    Function
highlight default link WorklogLogged      Special
highlight default link WorklogDuration    Special
highlight default link WorklogQuantError  Comment
highlight default link WorklogOption      PreProc
highlight default link WorklogNote        Comment

let b:current_syntax = "worklog"
