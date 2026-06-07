if exists("b:current_syntax")
  finish
endif

" Syntax for worklog.nvim (.wkl files). The matching mirrors the parser in
" lua/worklog/document.lua and lua/worklog/analyze.lua so highlighting agrees
" with how the plugin reads a file, and tests/highlight.lua guards the agreement:
"   * A worklog header is valid only when its body is a sequence (any order) of
"     at most one #tag, one @location, one q=<positive int> and one
"     d=dec|hm, with no other tokens. An invalid header falls back to
"     a generic block header rather than highlighting bad metadata.
"   * Entries and summary rows treat only a TRAILING run of #tag / @location / !L
"     as metadata, each kind at most once, in any order. A '#word' earlier in the
"     text is plain text, and a run with a repeated kind highlights nothing.
"   * Any non-blank line that is not a header, timestamp, or summary row is a
"     free-form note, whether indented or at column 0.

" Shared token patterns, defined once so the highlighter stays aligned with the
" parser.
let s:tag = '#[[:alnum:]_-]\+'
let s:loc = '@[[:alnum:]_-]\+'
let s:quantize = 'q=\d*[1-9]\d*'
let s:duration = 'd=\%(dec\|hm\)'

" Forbid a kind from appearing twice on the line (a repeat the parser rejects).
" Shared by the header body and the entry metadata run below.
function! s:no_repeat(token) abort
  return '\%(.*\s' . a:token . '.*\s' . a:token . '\)\@!'
endfunction

" Notes --------------------------------------------------------------------
" Defined first so all later, more-specific patterns (headers, timestamps,
" durations) can override it at column 0. contains=NONE keeps the whole line
" dimmed and stops the trailing-metadata match from firing inside it.
syntax region WorklogNote start=/^\s*\S/ end=/$/ contains=NONE keepend

" Block headers ------------------------------------------------------------
" Generated section headers, e.g. --- summary --- or --- tags ---
syntax match WorklogBlockHeader /^---\s.\+\s---$/

" Worklog headers ----------------------------------------------------------
" Defined after the generic header so it wins for the lines it matches. The body
" must consist only of valid tokens (so an unknown option, a bad value, or junk
" makes the whole match fail), and the leading lookaheads forbid a repeated tag,
" location, quantize or duration. A header the parser would flag therefore falls
" back to the generic block header above instead of highlighting bad metadata.
let s:header_token = '\%(' . s:tag . '\|' . s:loc . '\|' . s:quantize . '\|' . s:duration . '\)'
let s:header_no_dup =
  \ s:no_repeat(s:tag) . s:no_repeat(s:loc) . s:no_repeat('q=') . s:no_repeat('d=')
execute 'syntax match WorklogHeader '
  \ . '/^--- worklog' . s:header_no_dup . '\%(\s\+' . s:header_token . '\)*\s*---$/'
  \ . ' contains=WorklogTag,WorklogOoo,WorklogLocation,WorklogOption'
unlet s:header_token s:header_no_dup

" Entry timestamps: a valid HH:MM at the start of a line (00:00-23:59, plus the
" 24:00 end-of-day boundary), mirroring the time validation in document.lua so
" out-of-range times like 99:99 are not highlighted. The trailing lookahead
" requires whitespace or end-of-line after the time, matching the parser's rule
" that an entry needs a space after the timestamp, so "12:34xyz" is not a time.
syntax match WorklogTimestamp /^\%(\%([01]\d\|2[0-3]\):[0-5]\d\|24:00\)\%(\s\|$\)\@=/

" Summary rows -------------------------------------------------------------
" Generated rows start at column 0 with a duration followed by a (+Nm) rounding
" error. A decimal duration is unambiguous. For hhmm (H:MM) durations a
" single-digit hour cannot be an entry (entries are zero-padded HH:MM), and a
" duration directly before a (+Nm) error is a summary row, never an entry --
" including a two-digit-hour row like "16:00 (+0m) workday"; these are defined
" after WorklogTimestamp so they win at the same position. The WorklogSummaryBlock
" region below additionally gives every summary row its block context.
syntax match WorklogDuration /^\d\+\.\d\+h/
syntax match WorklogDuration /^\d:\d\d\%(\s\|$\)\@=/
syntax match WorklogDuration /^\d\+:\d\d\ze ([+-]\d\+m)/
syntax match WorklogQuantError /([+-]\d\+m)/

" A generated summary section gives its H:MM rows the block context the line
" matches lack: inside one, a two-digit-hour duration ("16:00 workday") is a
" duration, not an entry. `transparent` plus the ALLBUT contains keeps every other
" token highlighting while suppressing the entry-timestamp match; each
" blank-separated section is its own region, ending at the blank line (or EOF) that
" closes it. The start matches only generated section headers, so "--- worklog",
" user dividers, and labeled report headers (handled above) are
" excluded. fromstart sync is required so the region is recognized regardless of
" the window's scroll position.
syntax region WorklogSummaryBlock matchgroup=WorklogBlockHeader
  \ start=/^--- \%(summary\%( q=\d\+ d=\a\+\)\?\|tags\|locations\|logged\|totals\)\%( \%(exact\|quantized\)\)\? ---$/
  \ end=/^$/ end=/\%$/
  \ transparent keepend
  \ contains=ALLBUT,WorklogTimestamp,WorklogNote
syntax match WorklogDuration /^\d\d:\d\d\%(\s\|$\)\@=/ contained
syntax sync fromstart

" Trailing metadata --------------------------------------------------------
" document.lua consumes a trailing run of whitespace-separated #tag / @location /
" !L tokens (any order) at the end of an entry, but rejects the whole entry if a
" kind repeats. Same idea as the header above: a run of valid tokens guarded by
" the no-repeat lookaheads. Two entry-only details: the run is anchored to end of
" line (the trailing `\s*` tolerates whitespace the parser ignores, and text after
" the run ends it, leaving it plain); and a leading negative lookbehind stops the
" match from starting in the middle of a run -- without it a run with a repeated
" kind would still match a valid trailing suffix (e.g. `#b` in `#a #b`) instead of
" nothing. Tokens inside are highlighted by the contained matches below.
let s:meta_token = '\%(' . s:tag . '\|' . s:loc . '\|!L\)'
let s:meta_no_dup = s:no_repeat(s:tag) . s:no_repeat(s:loc) . s:no_repeat('!L')
let s:meta_not_mid = '\%(\s' . s:meta_token . '\)\@<!'
execute 'syntax match WorklogMeta '
  \ . '/' . s:meta_not_mid . s:meta_no_dup . '\%(\s\+' . s:meta_token . '\)\+\s*$/'
  \ . ' contains=WorklogTag,WorklogOoo,WorklogLocation,WorklogLogged'
unlet s:meta_token s:meta_no_dup s:meta_not_mid

" Metadata tokens ----------------------------------------------------------
" These are 'contained' so they only highlight inside a worklog header or a
" trailing metadata run, never mid-text. The whitespace lookbehind stops a '#'
" inside a word (foo#bar) from matching. The #-/@- clear tokens fall through to
" the tag/location matches on purpose, so they read like ordinary metadata.
execute 'syntax match WorklogTag /\s\@<=' . s:tag . '/ contained'

" #ooo is special: it counts toward activity but is excluded from workday.
" Defined after WorklogTag so it wins at #ooo; the lookahead avoids matching
" longer tags like #ooops or #ooo-bar.
syntax match WorklogOoo /\s\@<=#ooo\%([[:alnum:]_-]\)\@!/ contained

execute 'syntax match WorklogLocation /\s\@<=' . s:loc . '/ contained'

" !L is only valid on entries/summary rows, so it is not in the header's contains.
syntax match WorklogLogged /\s\@<=!L/ contained

" key=value options are only valid in worklog headers, and only quantize and
" duration with a valid value (matching analyze.lua).
execute 'syntax match WorklogOption /\s\@<=\%(' . s:quantize . '\|' . s:duration . '\)/ contained'

unlet s:tag s:loc s:quantize s:duration
silent! delfunction s:no_repeat

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
