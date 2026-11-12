# Browser and Ruby feedback evidence

Evidence index for the 17 reports reviewed on 2026-11-12. Status describes Mochi framework evidence; passing a product integration test does not establish a general contract.

| Report | Framework evidence/status | Owner |
| --- | --- | --- |
| 001 Conditional/hash classes in each | Reproduced: conditional class helper compilation failure. Hash-form class still needs a fixture. | E2.S2 |
| 002 Method calls in class attributes | Passing in isolation for a simple bare method; original complex context remains an investigation target. | E2.S2, E2.S4 |
| 003 Loop-local event arguments | Passing in isolation for a simple keyed-row handler; nested/reordered cases remain open. | E2.S2 |
| 004 Keyed table rows | Reproduced: row text slot missing in table context. | E2.S3 |
| 005 Dynamic child props | Passing for simple nested String props; conditional Hash and mixed contexts remain open. | E3.S2 |
| 006 Multiple typed-prop siblings | Reproduced: five four-prop children fail; two simple children pass. | E3.S1, E3.S3 |
| 007 Scratch object exhaustion | Reported 540-row case passes; exact exhaustion and recovery need framework-owned coverage. | E5.S1, E5.S2 |
| 008 Emitter receives its own implicit global event | Contract gap: delivery currently broadcasts to matching methods without explicit subscription. | E4.S1, E4.S2 |
| 009 Root-level conditional | Reproduced: both initial states compile to an empty descriptor. | E2.S1 |
| 010 Currency expects integer minor units | Intentional unit contract; observed truncation belongs to product calculation and is not a formatter defect. | E7.S1, E7.S2 |
| 011 Bare methods remain literal in attributes | Passing for a simple probe; unresolved binding detection remains open. | E2.S2, E2.S4 |
| 012 Missing numeric/collection helpers and with | Capability gap for reported Ruby helpers; `{with}` is deferred syntax requiring explicit diagnosis. | E6.S1–E6.S3, E2.S2 |
| 013 Relative icon href on deep routes | Reproduced: helper emits route-relative asset URL. | E10.S1 |
| 014 Compiler discovery | Capability gap: no supported installed development launcher/resource discovery workflow. | E10.S2, E10.S3 |
| 015 Pointer capture | Capability gap: no Ruby pointer identity/capture/release/cancellation contract. | E8.S1, E8.S2 |
| 016 Drag transfer data | Capability gap: no native typed/text transfer or bounded OS-file read contract. | E9.S1–E9.S4 |
| 017 Intermittent attribute placeholders | Unverified intermittent report; control mount/resource order and capture first failure. | E2.S4, E3.S1 |

The standalone fixture in `e2e/fixtures/framework_contracts` is checked-in Ruby source and compiles through Mochi. Its three-engine browser test does not use product routes, fixtures, or a Cowboy checkout.
