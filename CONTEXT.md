# CONTEXT.md — Domain Glossary

The domain language of the commenter gem. Used to name modules and commands;
keep this current when concepts sharpen.

- **Comment Sheet** — one ballot submission as a whole: metadata (document,
  stage, date, project, titles) plus its comments. `CommentSheet`.
- **Comment** — a single remark on a document: identity (id, member body),
  locality (clause, element, line), type, the remark text, the proposed
  change, and the disposition (`observations`).
- **Member Body** — the national body or committee that submitted the comment
  (`DE`, `US`, `CS` for the ISO/CS secretariat, `**` for ISO itself). A
  secretariat receives one sheet per member body per ballot.
- **Ballot** — the set of all comment sheets for one ballot round. Merging
  member sheets into one is collation; `Ballot`.
- **Disposition** — the resolution of a comment: accepted, accept with
  modifications, noted, rejected, or still open. `DispositionStatus` is the
  single matcher for both free-text observations and OSD's structured
  `resolution_status`.
- **Stage** — the ballot stage of the document (WD, CD, DIS, FDIS, PRF, PUB).
  The same comment ID at different stages is a different comment.
- **Redline** — a DOCX with tracked changes (`w:ins`/`w:del`/moves), typically
  from ISO/CS editors; also carries reviewer remark threads.
- **OSD** — ISO Online Standards Development; its XLSX comment exports come
  in resolved and unresolved variants.
- **Unique ID** — stage-aware identity of a comment's GitHub issue
  (`[DIS] GB-001` by default), used for duplicate detection.
