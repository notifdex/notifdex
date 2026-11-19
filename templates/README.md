# Relationship templates

Founder Outreach is a workflow for inviting contacts to try Inference Exchange.
It starts at Contacted. Milestones can be checked or cleared at any stage.

Each JSON definition has an `id`, positive integer `version`, `name`, ordered
`stages`, and `milestones`. Every stage and milestone has an `id` and `name`.
IDs use lowercase ASCII letters, digits, and hyphens, with no leading,
trailing, or consecutive hyphens. Names must contain non-whitespace text.
Use at least one stage. Its first entry is the initial stage. IDs are unique
within each list. An empty milestone list is valid.

Propose definitions in this directory. Give new templates their own ID. When
changing a released definition, add a new version in a separate file. Keep IDs
for stages and milestones whose meanings carry forward. Assigned people keep
their installed version and progress. The current app offers the bundled
Founder Outreach v1 definition in People. Additional definitions can use the
same Swift decoder and store API as the bundled definition.
