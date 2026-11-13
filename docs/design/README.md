# Design notes

How this project took its shape, for anyone who wants to extend it or question a choice.

- [use-cases.md](use-cases.md): the use case map the work started from. Every `UC-NNN` is a stable id;
  the README's "Use cases" section is the short version of this list.
- [decisions.md](decisions.md): architecture decision records (ADRs). One entry per choice that is
  hard to reverse, with the context, the decision and what it costs.

The method was simple: list every scenario first (actors, lifecycle, operations, edge cases,
integrations), prioritise with MoSCoW, cut a vertical slice that works end to end, then build that
slice with tests as the contract. New work follows the same path: add a use case, decide, record.
