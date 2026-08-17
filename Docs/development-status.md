# Stable baseline and experimental development

Last reviewed 2026-08-17. Stable public baseline: `main` at `c3d93494f72f9cc8c3dfcb673c616f668e07590d`.

The following branches are read-only development context and are **not merged** into stable main:

- `env-completion/phase2-radiance` at `353f2c887feae90988e42e2ef889a27cdaebac82`
- `env-completion/phase1-exposure`
- `phase6/night-celestial`

They contain ongoing celestial/day-night reconstruction, engine-wide automatic/manual/physical exposure work, and radiometric twilight, cloud and fog work. The visible night sky and scene illumination still disagree visually, so these changes are intentionally withheld from the public baseline. Continuous IBL/reflection-probe scheduling is also still pending. Beginner documentation must not present any of this work as available.
