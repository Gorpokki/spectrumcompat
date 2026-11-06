# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project purpose

Compatibility mod bridging **Spectrum** with **the Aether**, **Deep Aether**, **VanillaBackport**, **Copper Age Backport** and **Better Archeology** (all optional). NeoForge mod for Minecraft 1.21.1. Contributes mob-head block-items for every supported mob, all tagged into `#c:skulls`, plus a `spectrum:treasure_hunter` loot-modifier entry per mob — which automatically plugs into Spectrum's Treasure-Hunter enchant, Spirit-Instiller memory-to-head recipe, and head-fusion recipes without any Java interop. Better Archeology is a pure data-side integration (Spectrum Enchanter recipes for BA's enchantments + cross-tag entries), no heads.

## Spectrum integration pattern

`de.dafuqs.spectrum.blocks.mob_head.SpectrumSkullType` is a closed `enum`, so we cannot add our heads to Spectrum's own skull registry. Three hooks cover every interaction path instead:

1. **Loot drops / Head-Fusion / Memory-creation.** `TreasureHunterLootModifier` (type `spectrum:treasure_hunter`) is data-driven and accepts any item as `head_stack`. Our heads are tagged `#c:skulls`, so Spectrum's whole ecosystem — Treasure-Hunter enchant drops, head-fusion recipes, Spirit-Instiller memory-creation — consumes them without code changes.
2. **Spawner-Creature-Change.** `SpawnerCreatureChangeRecipe` calls `SpectrumSkullBlock.getEntityTypeOfSkullStack(ItemStack)` to turn the head back into an `EntityType`. We `@Inject` into that method (`SpectrumSkullBlockMixin`) to recognise our heads and return the matching Aether / Deep-Aether `EntityType`.
3. **Memory → Head (Spirit Instiller).** This Spectrum recipe currently consumes ingredients and produces nothing for any entity that lacks a weapon-item damage source, because `TreasureHunterLootModifier` short-circuits on `damageSource.getWeaponItem() == null` before the `ALWAYS_DROPS_MOB_HEAD` override fires. We therefore deliberately **do not** enable this path — no mixin into `SpectrumSkullBlock.getSkullType(EntityType)` — so our entity memories fail `canCraftWithStacks` early and the player can't waste items. The bug affects vanilla Spectrum mobs too.

## Head system layout (Java)

- `HeadType` — enum implementing `SkullBlock.Type`. One value per head (so mobs with variants have multiple entries — see "Variant filtering" above). Holds `requiredModId`, `entityId`, `textureLocation`, `blockName`. Single source of truth for registration, loot modifier, recipes, lang and client model/texture wiring. Exposes `activeTypes()` — a stream of enum values whose `requiredModId` is loaded. **`activeTypes()` is called once from the `SpectrumCompat` constructor to decide which types to register.** Post-registration code paths don't re-filter through `ModList` — they iterate the registered-entry maps (`HEAD_ITEMS`, `FLOOR_BLOCKS`, `WALL_BLOCKS`) directly, which are guaranteed by construction to contain exactly the active types.
  - **Three constructors** in increasing specificity:
    1. `(namespace, path, texture)` — Aether/DA single-variant. `requiredModId = namespace`, `blockName = path`.
    2. `(requiredModId, entityNamespace, entityPath, texture)` — cross-namespace single-variant (VB Happy Ghast). Entity lives under `minecraft:` but gating mod is separate.
    3. `(requiredModId, entityNamespace, entityPath, blockName, texture)` — variant entries, where multiple heads share one entity type but need distinct block names and textures (Moa / Quail / Copper Golem).
- `HeadBlock extends SkullBlock` and `WallHeadBlock extends WallSkullBlock` — thin subclasses that take an `AetherHeadType`. Vanilla provides `ROTATION_16`, wall `FACING`, waterlog, placement logic and default voxel shape.
- `SpectrumCompat` — registers a floor + wall block pair plus one shared `StandingAndWallBlockItem` per *active* mob, like every vanilla skull. Because `ModList` is not reliably available during class init, the registration loop runs in the mod constructor (not a `static {}` block). The public `FLOOR_BLOCKS` / `WALL_BLOCKS` / `HEAD_ITEMS` `EnumMap`s are populated by that loop and iterated in enum-declaration order; they are the authoritative "what was registered" source for every downstream consumer (creative tab, BE-type `validBlocks` swap, mixin lookup, client wiring).
- `BlockEntityTypeAccessor` (mixin) — swaps `BlockEntityType.SKULL.validBlocks` for a mutable copy that also contains the *active* head blocks during common setup. Without this, `level.getBlockEntity(pos)` returns null on our heads and the vanilla renderer never fires.
- `SpectrumSkullBlockMixin` — recovers the source `EntityType` from a head `ItemStack` via `HeadLookup.fromItemStack(stack)` and returns it from `SpectrumSkullBlock.getEntityTypeOfSkullStack`. Enables Spectrum's spawner-creature-change recipe on our heads.
- `SpawnerCreatureChangeRecipeMixin` — injects at `RETURN` of `SpawnerCreatureChangeRecipe.getSpawnerResultNbt` to add variant-identifying NBT (MoaType / Variant / weather_state) to the target spawner's `SpawnData.entity` compound. Without it, changing a spawner with e.g. a blue_moa_head produces a spawner that rolls a random Moa type. Uses `require = 0` so an upstream Spectrum rename silently degrades (spawner still changes, variant defaults to random) rather than blocking load. For variant info the mixin delegates to `HeadLookup.applyVariantNbt(HeadType, CompoundTag)`.
- `HeadLookup` — non-mixin helper class holding the shared {stack → HeadType} reverse lookup plus the variant-NBT applier map (`HeadType → Consumer<CompoundTag>`). Single source of truth for the NBT key/value mapping; both the spawner-change mixin and the memory recipe JSONs are kept in sync with it by hand. If a variant's NBT format changes upstream (verified via `addAdditionalSaveData` bytecode), update `HeadLookup.VARIANT_APPLIERS` **and** the corresponding entries in `aether_heads.json` / `deep_aether_heads.json` / `copperagebackport_heads.json` + the `entity_data` blocks in `data/spectrumcompat/recipe/spirit_instiller/memories/*.json`.
- `client/SpectrumCompatClient` — hooks `EntityRenderersEvent.RegisterLayerDefinitions` (unconditional — layer definitions are pure geometry, cheap), `EntityRenderersEvent.CreateSkullModels` (iterates `SpectrumCompat.HEAD_ITEMS.keySet()`) to plug a `SkullModelBase` into the vanilla `SkullBlockRenderer`, and on `FMLClientSetupEvent` writes the per-type texture into `SkullBlockRenderer.SKIN_BY_TYPE` for registered types only (the map is a mutable `HashMap` in vanilla, which is the supported extension mechanism for third-party skull types). The `SCALE_FOR` table maps layer locations to a uniform scale factor applied at bake time (e.g. Moa-like 2.0×, Aerwhale 4/7×, default 1.0×); layers absent from `SCALE_FOR` bake to `ConfigurableHeadModel` unscaled. Most heads use the plain skeleton-skull layer; pig-layout mobs (Phyg, Flying Cow) use `SnoutedHeadModel` with an extra snout cube. Add new geometries by creating a new `ModelLayerLocation` in `HeadLayers`, a `SkullModelBase` subclass, mapping the appropriate `AetherHeadType`s in `LAYER_FOR`, and optionally adding a `SCALE_FOR` entry if the bake needs uniform scaling.

## Textures — referenced, never copied

Every texture path in `AetherHeadType` points at `aether:textures/entity/...` or `deep_aether:textures/entity/...`. The PNGs are loaded from Aether's or Deep Aether's jar at runtime; **this mod ships zero texture bytes**. Required because of Aether's license. When validating a new texture path, cross-check against `src/main/resources/assets/<namespace>/textures/entity/` in the corresponding mod's GitHub tree — the naming is not always obvious (e.g. Phyg at `entity/mobs/phyg/phyg.png`, DA Quail at `entity/quail/quail_tropical_blue.png`).

## Data contract files

- `data/c/tags/item/skulls.json` — puts every head into `#c:skulls`. Merges with Spectrum and vanilla entries; never set `replace: true`. Entries use the object form `{ "id": "...", "required": false }` so the tag loader silently skips entries whose items are not registered (e.g. when Aether or Deep Aether isn't installed and those heads aren't created).
- `data/neoforge/loot_modifiers/global_loot_modifiers.json` — registers both modifier files below.
- `data/spectrumcompat/loot_modifiers/aether_heads.json` — `spectrum:treasure_hunter` entries for the 17 Aether mobs, gated by top-level `"neoforge:conditions": [{"type":"neoforge:mod_loaded","modid":"aether"}]` so the whole file is skipped when the Aether isn't installed.
- `data/spectrumcompat/loot_modifiers/deep_aether_heads.json` — same for the 5 Deep Aether mobs, gated by the equivalent `neoforge:mod_loaded` condition on `deep_aether`.
- `data/spectrumcompat/loot_modifiers/vanillabackport_heads.json` — Happy Ghast entry, gated on `vanillabackport`.
- `data/spectrumcompat/loot_modifiers/copperagebackport_heads.json` — Copper Golem entries with int `weather_state` NBT, gated on `copperagebackport`.
- `data/spectrumcompat/loot_modifiers/vanillabackport_copper_golem_heads.json` — same entries with string `weather_state` NBT for VB ≥ 1.2's golem, gated on `neoforge:item_exists spectrumcompat:copper_golem_head` + `not copperagebackport`. The Copper Golem memory recipes are split the same way (`memories/*copper_golem.json` for CAB, `memories/vanillabackport/*copper_golem.json` for VB); the format-independent copper files (pool tag, wax recipes) gate on `neoforge:item_exists` instead of a mod id.
- `CopperGolemSource` — detects whether CAB or VB ≥ 1.2 provides `minecraft:copper_golem` (CAB wins if both are loaded). `HeadType.activeTypes()` activates the Copper Golem heads for either provider, and `HeadLookup` writes `weather_state` in the provider's format.
- `data/spectrumcompat/tags/item/mob_heads/{moa,quail,copper_golem,chicken,cow,pig}_heads.json` — one sub-tag per variant pool. Mirrors Spectrum's own `spectrum:mob_heads/<family>_heads` organisation. Each file is `neoforge:conditions`-gated on the matching source mod. The `chicken/cow/pig` tags include Spectrum's own `spectrum:chicken_head` / `cow_head` / `pig_head` (the temperate variant) alongside our warm/cold heads, so `#spectrumcompat:mob_heads/chicken_heads` is "all chicken variant heads across mods".
- `ServerAdvancementManagerMixin` — runtime-patches Spectrum's `spectrum:midgame/collect_all_mob_heads` advancement at datapack load by mutating the JSON `criteria` object before vanilla parses it. `HEAD_ITEMS` already reflects which source mods are loaded (registration is gated by `HeadType.activeTypes()`), so the injected criterion set scales automatically with the installed modpack: missing source mod → no corresponding head criteria injected. Injection groups `HEAD_ITEMS` by `entityId`: **single-variant mobs** (entity with one HeadType, e.g. Phyg) get a per-head criterion targeting the exact item; **variant pools** (entity with multiple HeadTypes, e.g. Moa's three colours) collapse to **one** tag-based criterion against `#spectrumcompat:mob_heads/<entityPath>_heads` — so the player only needs to collect any one variant per pool, not every variant. For the chicken / cow / pig pools (where Spectrum already defines `has_chicken_head` / `has_cow_head` / `has_pig_head` as single-item criteria and our pool tag includes Spectrum's generic head alongside our warm / cold variants), the injected pool criterion reuses Spectrum's criterion name so it overwrites the single-item requirement; for moa / quail / copper_golem (where Spectrum has nothing) we use a plural `has_<entityPath>_heads` name. No static override file ships under `data/spectrum/...`, so future Spectrum updates that add new vanilla heads integrate naturally. Mixin uses `require = 0` so a future MC/NeoForge signature refactor silently no-ops instead of blocking load.
- `de.mwojt.spectrumcompat.loot.VariantHeadDedupeHandler` — `@EventBusSubscriber`-registered `LivingDropsEvent` listener. Strips Spectrum's generic `spectrum:chicken_head` / `cow_head` / `pig_head` from the drops of any chicken/cow/pig whose `variant` NBT is present and not `minecraft:temperate`. **Uses `LivingDropsEvent` instead of a `LootModifier`** because cross-mod `IGlobalLootModifier` ordering isn't guaranteed: we can't rely on our dedupe modifier running *after* Spectrum's `treasure_hunter`. `LivingDropsEvent` fires after the entire loot pipeline, so the generic head is always in `event.getDrops()` by the time we inspect it. No explicit mod-loaded gate needed — the `variant` NBT only exists when VB is loaded, so the handler degrades to a no-op otherwise.

### Variant-lock for memory-spawned Chicken / Cow / Pig

VB's `ChickenMixin` / `CowMixin` / `PigMixin` each inject at `@At("RETURN")` of `finalizeSpawn` and *unconditionally* overwrite the entity's variant with the biome-appropriate one. That breaks Spectrum's Memory manifestation for these mobs: a memory crafted from `spectrum:chicken_head` (representing a temperate chicken) would always respawn as the local-biome variant (e.g. warm in a desert).

**Fix**: a three-part compat layer, gated entirely by `vanillabackport` being loaded:

1. `data/spectrum/recipe/spirit_instiller/memories/{chicken,cow,pig}.json` — our override of Spectrum's own memory recipe (same path, our mod loads after Spectrum so ours wins). Adds `variant: "minecraft:temperate"` plus a marker byte `spectrumcompat_lock_variant: 1` to the result's `entity_data` component. Our own `warm_*` / `cold_*` memory recipes carry the same marker so their variant is also preserved.
2. `de.mwojt.spectrumcompat.VariantLocked` (interface) + `LivingEntityVariantLockMixin` — mixes the interface into `LivingEntity` with a `@Unique boolean` flag and captures the marker at `@At("TAIL")` of `LivingEntity.readAdditionalSaveData`. The flag is read at `@At("HEAD")` of `vb$finalizeSpawn` by three per-species mixins (`Chicken`/`Cow`/`Pig`VariantLockMixin); if set, they consume the flag and cancel the VB callback. VB changed that hook's shape in 1.2 (≤1.1.x: `void vb$finalizeSpawn(…, CallbackInfoReturnable)` `@Inject` handler; ≥1.2.x: `SpawnGroupData vb$finalizeSpawn(…)` virtual hook called from VB's `MobMixin`), so each lock mixin carries **two** injectors with explicit descriptors — selecting by name alone hard-fails with "Invalid descriptor" regardless of `require`. `require = 0` on each `vb$finalizeSpawn` inject so a future VB rename degrades silently (biome override resumes, memories revert to double-spawn behaviour) instead of blocking load. The flag lives on LivingEntity because `Cow` doesn't override `readAdditionalSaveData` — a `@Mixin(Cow.class)` can't target a method it doesn't define, and LivingEntity is the lowest shared supertype that does. The flag is per-entity, one-shot — so save/load of a previously-locked entity doesn't permanently suppress biome selection on a later respawn.
3. The `VariantHeadDedupeHandler` (above) is unaffected — it reads the final entity state, which is now correctly `minecraft:temperate` after load, so Spectrum's generic head is preserved on temperate memory-spawned chickens as expected.
- `data/spectrumcompat/recipe/spirit_instiller/memories/<head>.json` — one Spirit-Instiller recipe per head type (head + thematic item + 4× `#spectrum:memory_bonding_agents` → `spectrum:memory`). One recipe per variant too — e.g. `blue_moa.json`, `white_moa.json`, `black_moa.json` — each using the same `ingredient2` (Moa uses `aether:aechor_petal`, Quail uses `deep_aether:raw_quail`) since the memory is keyed to the entity type, not the variant. Copper Golem variants each use their corresponding vanilla copper block. Every recipe is gated on the source mod.
- `data/spectrumcompat/recipe/crafting_table/wax/waxed_*_copper_golem_head.json` — 4 shapeless crafting-table recipes that turn an unwaxed Copper Golem head + `minecraft:honeycomb` into the waxed variant with matching oxidation state. This is how waxed heads enter the player's hands since waxed golem entities don't exist.
- `data/spectrumcompat/recipe/anvil_crushing/dye/<dye>_from_<flower>.json` — anvil-crushing recipes mirroring Spectrum's own `cornflower`/`sunflower` convention: **yield = 2× the upstream crafting-table yield**. Most flowers craft to 1 dye upstream (→ we give 2), but some (like `golden_flower`, tall flowers) already craft to 2 upstream (→ we give 4). Always read the upstream recipe's `result.count` rather than assuming by block height. Covers every Aether/DA/VB flower with an upstream crafting-table dye recipe — 2 Aether (`purple_flower`, `white_flower`) + 11 Deep Aether (`golden_flower`, `sky_tulips`, `iaspove`, `aether_cattails` + tall, `golden_aspess`, `aerlavender` + tall, `echaisy`, `radiant_orchid`, `enchanted_blossom`) + 4 VanillaBackport (`closed_eyeblossom`, `open_eyeblossom`, `cactus_flower`, `wildflowers`). Each recipe is gated by `neoforge:conditions` on its source mod. When adding new source mods, grep their jar for `data/<mod>/recipe/*_dye_from_*.json` (or `data/minecraft/recipe/*_dye_from_*.json` for mods that register into `minecraft:`) to find upstream flower→dye mappings and mirror them here.
- `data/spectrumcompat/loot_table/blocks/<mob>_head_wall.json` — explicit wall loot table for every head because `StandingAndWallBlockItem` only binds to the floor block; without these, breaking a wall head drops nothing. `.dropsLike(floor)` in the block properties is not usable during static init (the `DeferredBlock` is unbound then), so the JSON path is the reliable way.
- `assets/spectrumcompat/blockstates/<mob>_head.json` + `<mob>_head_wall.json`, `assets/spectrumcompat/models/item/<mob>_head.json` — every file parents `minecraft:block/skull` or `minecraft:item/template_skull`. No custom block or item geometry is defined in JSON — rendering is 100% BER.

## Better Archeology integration (data-only)

Pure data-side, no Java, no mixins. Every file is gated by a top-level `neoforge:conditions` mod_loaded check on `betterarcheology`, so the integration no-ops when BA isn't installed.

- `data/spectrum/recipe/enchanter/<ba_enchantment>.json` — Spectrum Enchanter recipes producing a vanilla `enchanted_book` with a BA enchantment stored at level 1 via the `stored_enchantments` data component. **Files live under `data/spectrum/...`, not `data/spectrumcompat/...`** — Spectrum's Enchanter recipe loader is keyed by the Spectrum namespace, so this placement is what makes them visible in the Enchanter UI without a code-side hook.
- Exclusive-set cross-tags between Spectrum and BA enchantments. Both sides need the entry — vanilla's compatibility check reads each enchantment's own exclusive-set tag, so a one-sided patch leaves a gap where the other order still stacks. Currently: `data/spectrum/tags/enchantment/exclusive_set/disarming.json` ↔ `data/betterarcheology/tags/enchantment/exclusive_set/penetrating_strike.json`. Always `replace: false`.

When adding more BA enchantments, mirror the pattern: recipe under `data/spectrum/recipe/enchanter/`, and if it thematically conflicts with a Spectrum enchantment, add **both** sides of the exclusive-set tag.

## Dependency wiring

- `build.gradle` adds `https://api.modrinth.com/maven` (restricted to group `maven.modrinth`) and declares `localRuntime` for `aether`, `spectrum`, `deep-aether`. These are for `runClient`/`runServer` only — they're not published transitively. **Running the game will almost certainly need additional transitive `localRuntime` entries** (Spectrum alone pulls Revelationary, Fractal, AEA, Arrowhead, Modonomicon, etc.). Add them as needed; don't expect `./gradlew runClient` to boot out of the box.
- `neoforge.mods.toml` template declares `spectrum` as `required` (hard runtime dep — this mod mixes into Spectrum); `aether`, `deep_aether`, `vanillabackport`, `copperagebackport` and `betterarcheology` are all `optional`. When any of the head-providing mods (aether/deep_aether/vanillabackport/copperagebackport) is absent, `HeadType.activeTypes()` omits its entries, so the heads are not registered at all (no block, no item, no block-entity binding, no model, no texture entry), and the corresponding loot-modifier file + Spirit-Instiller/anvil-crushing recipes are skipped by `neoforge:mod_loaded` conditions. The `requiredModId`-based filter works for both normal (namespace = source-mod) and cross-namespace cases (VB and CAB, which register under `minecraft:`). `betterarcheology` is the odd one out — purely data-side (Enchanter recipes + cross-tags), no `HeadType` involvement; see the "Better Archeology integration" section. Version ranges live in `gradle.properties` as `aether_version_range`, `spectrum_version_range`, `deep_aether_version_range`, `vanillabackport_version_range`, `copperagebackport_version_range`, `betterarcheology_version_range` and are substituted into the toml via `generateModMetadata`.

## Mob coverage (current)

45 head types covering every player-killable mob for Aether 1.21.1-develop / Deep-Aether 1.21.1-1.1 / VanillaBackport 1.21.1-1.1.6 / Copper Age Backport 1.21.1-0.1.4:
- 16 Aether single-variant mobs
- 3 Moa variants (blue / white / black — one head per entry in `data/aether/aether/moa_type/`)
- 4 Deep Aether single-variant mobs
- 7 Quail variants (all entries of `QuailVariants` enum)
- 1 VanillaBackport mob (Happy Ghast)
- 6 VanillaBackport 1.21.2 biome-variant heads (Chicken / Cow / Pig × warm+cold — *not* temperate, which is Spectrum's own generic head)
- 8 Copper Golem variants (4 oxidation states × 2 wax states), provided by Copper Age Backport or VanillaBackport ≥ 1.2

Whirlwinds are deliberately excluded: `AbstractWhirlwind.hurt()` returns `false` (invulnerable) and their entity loot table is empty, so `spectrum:treasure_hunter` can never fire — the head would be unreachable via any Spectrum path. Gentle Wind is excluded for the same reason: `GentleWind.hurt()` returns `false`. The **Creaking** (VanillaBackport's pale-garden mob) is excluded for the same reason: `Creaking.hurt()` returns `false` and the only kill path is destroying the `creaking_heart` block, which emits no weapon-bearing `DamageSource`. Windflies are excluded because they have no biome spawner entries in any Deep Aether biome and no biome_modifier registers their spawn, so in survival they are only obtainable via the spawn egg and the head would be practically unreachable. Slider is excluded because the head is unobtainable in practice — plus as a single textured cube the head item would just look like a miniature slider block with no added value.

### Variant filtering

Variant heads share their entity type with siblings — e.g. all three Moa variants map to `aether:moa`. Drops are disambiguated via the `nbt` field on Spectrum's `treasure_hunter` entries, which delegates to vanilla's `EntityPredicate` + `NbtPredicate` (sub-tree NBT match against the killed entity's save NBT). Keys / value formats (verified from each mod's `addAdditionalSaveData` bytecode):

- **Moa** (`aether:moa`): NBT key `"MoaType"`, value is a ResourceLocation **string** — `"aether:blue"`, `"aether:white"`, `"aether:black"`.
- **Quail** (`deep_aether:quail`): NBT key `"Variant"`, value is an **int ordinal** 0..6 (OLD_GREEN=0, PINK=1, PURPLE=2, TROPICAL_BLUE=3, FADED_YELLOW=4, LIGHT_BLUE=5, COPPER=6).
- **Copper Golem** (`minecraft:copper_golem`, from CAB *or* VB ≥ 1.2): NBT key `"weather_state"`. On **CAB** the value is an **int ordinal** 0..3 on `WeatheringCopper$WeatherState` (UNAFFECTED=0, EXPOSED=1, WEATHERED=2, OXIDIZED=3); on **VB** it is the `WeatherState` serialized-name **string** (`"unaffected"`, `"exposed"`, `"weathered"`, `"oxidized"`, via `getSerializedName()` / `WeatheredData.fromName`). Both mods ship pixel-identical golem textures at the same paths. When re-checking after an upstream CAB change, inspect `CopperGolemEntity.addAdditionalSaveData` bytecode — the mod currently uses `putInt("weather_state", state.ordinal())`.
- **Chicken / Cow / Pig** (1.21.2 biome variants, backported by VB): NBT key `"variant"`, value is a ResourceLocation **string** — `"minecraft:temperate"`, `"minecraft:warm"`, `"minecraft:cold"`. We register only warm + cold; temperate is Spectrum's stock `spectrum:chicken_head` / `cow_head` / `pig_head`. To avoid a double-drop when VB *is* loaded (Spectrum's treasure_hunter would still add its generic head on top of ours), the `VariantHeadDedupeLootModifier` strips Spectrum's generic from the loot of any chicken/cow/pig whose `variant` NBT is present and not `minecraft:temperate`. VB's shared variant layer (`com.blackgear.vanillabackport.common.api.variant.VariantUtils`) is what writes the `variant` key, using `putString(...)` with the ResourceLocation string — confirmed in VB's bytecode.

Waxed Copper Golem variants don't drop from kills — CAB's wax mechanic transforms a killable entity into a permanent statue block, so no waxed Copper Golem ever dies from a weapon. Their heads are instead obtainable via `crafting_table/wax/waxed_*_copper_golem_head.json` (unwaxed head + honeycomb, mirroring vanilla copper waxing). All eight variants have memory recipes using the corresponding vanilla copper block as `ingredient2` (`copper_block` for the unoxidized default, `exposed_copper` / `weathered_copper` / `oxidized_copper` for the oxidation states, `waxed_*` for the waxed ones). Variants (Moa color, Sheepuff wool) collapse to one head each:
- **Sheepuff** — its skin texture is uniform; wool color is a runtime overlay. A single head is visually correct for every color.
- **Moa** — variant is a custom string data-tracker (`DATA_MOA_TYPE_ID`) rather than a standard `minecraft:variant` NBT, so Spectrum's stock `type_specific` loot predicate can't filter on it without an Aether-specific predicate type. The default head uses `blue_moa.png`.

Bosses (Valkyrie Queen, Sun Spirit, EOTS Controller) are already blocked from spawner-creature-change by Spectrum's `#spectrum:spawner_manipulation_blacklisted` → `#c:bosses` tag chain — Aether and Deep Aether both contribute their bosses upstream, so we inherit the blacklist for free.

## Known upstream gaps (intentionally not fixed here)

**Aether ships incomplete `#minecraft:enchantable/*` tags.** Only `bow`, `vanishing` and `durability` get Aether entries upstream; `sword`, `weapon`, `sharp_weapon`, `mining`, `mining_loot`, `fire_aspect` and the four `*_armor` tags receive nothing. Deep Aether populates the full set, so it's specifically an Aether data-side oversight. **Same gap in AethersDelight** (4 knives, no enchantable tags at all) and **AppliedEnergistics2** (its three quartz swords are not in `sword`/`weapon`/`sharp_weapon`/`fire_aspect`, though its pickaxes/axes are tagged for mining).

**Consequence:** Spectrum's enchantments target vanilla tags (e.g. `treasure_hunter` → `#minecraft:enchantable/weapon`, `foundry` → `#minecraft:enchantable/mining_loot`), so they **cannot apply to the affected items** — no Treasure Hunter on a Skyroot Sword, no Foundry on a Gravitite Pickaxe, etc. The gap isn't Spectrum-specific; every enchantment mod (Apotheosis, Sophisticated Enchantments, etc.) hits the same wall, which is why it belongs upstream rather than here.

Not fixed because: patching vanilla tags from this mod would silently alter behaviour for every other enchantment mod in a modpack, well outside the "Spectrum ↔ Aether/DA/VB/CAB" scope. If it ever becomes a priority, the narrower approach is to add Aether/AD/AE2 items to Spectrum's **own** tags (`data/spectrum/tags/item/enchantable/<name>.json`, `replace: false`, mod-gated) — that keeps the override from leaking to other mods, at the cost of ~20 tag files and manual maintenance when upstream adds items.

## Build / run commands

All commands use the Gradle wrapper. Java 21 toolchain is required.

- `./gradlew build` — compile, run tests, produce the mod jar
- `./gradlew runClient` — launch a dev Minecraft client with the mod loaded
- `./gradlew runServer` — launch a dev dedicated server (`--nogui`)
- `./gradlew runGameTestServer` — launch the GameTestServer, run every registered gametest, then exit. **The server crashes if no gametests are registered** — only run this once gametests exist.
- `./gradlew runData` — run data generators, writing into `src/generated/resources/`
- `./gradlew --refresh-dependencies` — force re-resolve (use when IDE shows missing libraries)
- `./gradlew clean` — wipe `build/` (does not touch source)

GameTest namespaces are filtered to `spectrumcompat` via `neoforge.enabledGameTestNamespaces` in every run config. The `/test` command is available in the client and server run configs too.

## Versions and where they live

Mod / platform versions are centralized in `gradle.properties` (not `build.gradle`):
- `minecraft_version`, `neo_version`, `parchment_*`, `mod_version`, `mod_id`, `mod_group_id`
- When bumping Minecraft/NeoForge, update `minecraft_version_range` as well.

`mod_id` must match the `@Mod` annotation value in the main class (currently `SpectrumCompat.MODID`). It must also match the filename `src/main/resources/<mod_id>.mixins.json`.

## Architecture notes

### Mod metadata is generated, not static
`src/main/templates/META-INF/neoforge.mods.toml` uses Groovy `${...}` placeholders. The `generateModMetadata` task in `build.gradle` expands these (mod_id, mod_version, neo_version, version ranges, etc.) into `build/generated/sources/modMetadata/` and adds that directory to `sourceSets.main.resources`. **Edit the template, not the generated output** — and do not introduce a static `neoforge.mods.toml` alongside it. The task runs on every IDE project sync (`neoForge.ideSyncTask`).

### Data generation pipeline
`runData` writes into `src/generated/resources/`. That directory is added to the main resource set in `build.gradle` (with `**/*.bbmodel` and datagen `.cache` files excluded from final jars). Generated assets are intended to be committed — treat them as source-controlled output of the data generators, not as build artifacts.

### Entry points and dist split
- `SpectrumCompat` (common) — registers `BLOCKS`, `ITEMS`, `TABS` via `DeferredRegister` and wires `FMLCommonSetupEvent` to run the `BlockEntityType.SKULL.validBlocks` swap.
- `client/SpectrumCompatClient` — `@EventBusSubscriber(value = Dist.CLIENT)` on the mod bus. Hooks `RegisterLayerDefinitions`, `CreateSkullModels`, and `FMLClientSetupEvent`. Never referenced from the common class so dedicated-server loads don't classload client code.

### Mixins
`spectrumcompat.mixins.json` lists eight mixins under package `de.mwojt.spectrumcompat.mixin`:
- `BlockEntityTypeAccessor` — mutable accessor on `BlockEntityType.validBlocks` (needed to register our blocks with vanilla `BlockEntityType.SKULL`).
- `SpectrumSkullBlockMixin` — `@Inject` into `SpectrumSkullBlock.getEntityTypeOfSkullStack` so the spawner-creature-change recipe recognises our heads.
- `SpawnerCreatureChangeRecipeMixin` — `@Inject` at `RETURN` of `SpawnerCreatureChangeRecipe.getSpawnerResultNbt` to propagate variant NBT into the target spawner's `SpawnData.entity`. See "Variant filtering" in the head-system section.
- `ServerAdvancementManagerMixin` — `@Inject` at `HEAD` of `ServerAdvancementManager.apply` to append per-head criteria to Spectrum's `collect_all_mob_heads` advancement before vanilla parses the JSON. See the data-contract entry for details.
- `LivingEntityVariantLockMixin`, `ChickenVariantLockMixin`, `CowVariantLockMixin`, `PigVariantLockMixin` — cancel VB's biome-based variant override on memory-spawned animals. See "Variant-lock for memory-spawned Chicken / Cow / Pig" in the head-system section.

The Spectrum-target mixins (`SpectrumSkullBlockMixin`, `SpawnerCreatureChangeRecipeMixin`) use `remap = false` because the targets live in a third-party jar (pulled as `compileOnly` from Modrinth Maven). `LivingEntityVariantLockMixin` targets vanilla `LivingEntity.readAdditionalSaveData` with normal remapping. The three per-species locks target vanilla classes for the `@Mixin` target, but their `vb$finalizeSpawn` inject uses `remap = false` because VB added that method to each class via its own mixin (non-vanilla name — there is no mapping for it).

`overwrites.requireAnnotations = true` and `injectors.defaultRequire = 1` (inherited from the scaffold) — intentionally strict so mismatched injections fail the load rather than silently skipping.

### Access transformers
Not currently used. To enable, uncomment both the `accessTransformers` line in `build.gradle` and the `[[accessTransformers]]` block in the templated `neoforge.mods.toml`, then create `src/main/resources/META-INF/accesstransformer.cfg`. Auto-detection will pick it up without the explicit config line, but keep the toml block if the file is used.

### Parchment mappings
`build.gradle` pins Parchment (parameter names / javadoc on Minecraft classes) alongside NeoForge. Update `parchment_minecraft_version` and `parchment_mappings_version` together in `gradle.properties` when bumping.

## CI

`.github/workflows/build.yml` runs `./gradlew build` with Temurin JDK 21 on pushes to `main` and on PRs, then boot-checks the built jar on a dedicated server (`.github/boot-check.sh`). PRs also run a control leg that expects the upstream 0.1.0 jar to fail the boot check; pushes to `main` publish the jar to GHCR. Keep the build green — no separate lint step exists, so compile + test is the full gate.
