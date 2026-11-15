# Documentation rules

Use factual prose for architecture, feature descriptions, and procedures.
Use [ASD-STE100 Issue 9](https://www.asd-ste100.org/) as the controlled-English style target.
Use these rules when you add or change documentation.

## Writing rules

- Use active voice and present tense for system behavior.
- Give one instruction in each procedure step.
- Keep an instruction to 20 words where practical.
- Keep a descriptive sentence to 25 words where practical.
- Use one term for one concept.
- State limits next to the associated feature.
- Separate available behavior from planned behavior.
- Describe measured results without performance claims that exceed the evidence.

Do not change literal menu labels, commands, filenames, or protocol identifiers to satisfy a word choice rule.
Treat these identifiers as technical names.
Historical release notes retain their original wording.

## Technical terms

| Term | Meaning |
| --- | --- |
| Sharing Mac | The Mac that sends its display |
| Viewing Mac | The Mac that presents a remote display |
| Pairing | Approval of a native Mooring device key |
| Internet ID | Public Iroh transport identity |
| Locator | Expiring public endpoint and address information |
| Relay | Explicit server that forwards encrypted Iroh traffic |
| Noise | Native session authentication and encryption protocol |
| QUIC | Encrypted transport used by Iroh |
| SSH session | Authenticated OpenSSH connection with one or more channels |
| Domain context | A model and its associated business rules |
| Adapter | Implementation of an external effect at a defined boundary |
| Acceptance check | A required check on a real device or network |

## Availability labels

| Label | Use |
| --- | --- |
| Public preview | Included in the current signed public Mac download |
| Source | Included in the main source branch |
| Release candidate | Built for validation; public delivery is not yet complete |
| Experimental | Available with known limits and incomplete acceptance checks |
| Planned | No delivered implementation |

Do not call a candidate notarized until Apple accepts the exact archive.
Do not call a feature public merely because its source is public.
A demonstration proves only the path and behavior that it shows.
