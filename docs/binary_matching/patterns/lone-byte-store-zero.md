# Lone 4-byte `mov byte[ebp-N],0` with no lea/call - often a member store on a stack object (not an unused bool)
tags: cpp:bool cpp:local cpp:const | asm:mov | topic:codegen-idiom topic:assert-eater
symptoms: <0x4> statement, mov byte ptr [ebp-N],0 with no lea/call, no PDB local for the slot
confidence: 2/10
variants: assert-eater-recover.md, bool-const-local-codegen.md, and-chain-third-bool-temp.md

A statement of size <0x4> whose only instruction is a byte-store of zero, with no
following `lea eax; call <eater>` and NO matching PDB local. Do NOT write an unused
`bool b = false;` for it - this project has ~no unused variables (sushi), the PDB
records no such local, and a fabricated local violates the PDB-locals rule.
Candidate real origins, in likelihood order: (1) a compiler-MATERIALIZED bool temp -
a `false`/bool literal bound through a `bool const&` / builder-chain parameter site;
(2) the detached first record of a split assert eater (check the NEXT record for the
lea/call); (3) a short-circuit `&&` byte temp whose reader landed in another record.

```asm
mov byte ptr [ebp-5], 0    ; nothing follows in this record; no local in --view info
```
FIRST check whether `[ebp-N]` falls INSIDE a stack object (a local's base plus its size, from
`--view info`): then it is an inlined setter / member store on that object, not a temp.
Resolved site: game_core get_weapon_lexeme_pair_impl L40 - `[ebp-5]` is `[ebp-58h]+0x53`,
`main_lexeme_parameters.can_generate_events( false )`. Misreading it as a temp dropped real
behaviour (every weapon "shoot" event dispatched twice), so never leave such a store unexplained.
