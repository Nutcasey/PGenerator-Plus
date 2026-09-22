// A queued job named after its template but carrying different values is
// invisible on the queue row, which shows only the name. One such job ran a
// calibration with Dark Detail off and a 17-node solve while its row said
// "SDR Filmmaker". These are the properties of the drift badge that catch it
// without lighting up on every job somebody legitimately customised.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.join(__dirname, '../../usr/share/PGenerator');
const context = vm.createContext({
 document:{querySelectorAll:() => [], getElementById:() => null},
 localStorage:{setItem:() => {}},
 setTimeout:() => {},
 fetchJSON:() => {throw new Error('drift detection must not contact the TV');},
 getCcssOverride:() => 'my-panel.ccss', getMeterRefreshRate:() => '24',
});
vm.runInContext(fs.readFileSync(path.join(root, 'webui-automation.js'), 'utf8'), context);
const evaluate = code => vm.runInContext(code, context);
const clone = value => JSON.parse(JSON.stringify(value));
const build = mode => clone(evaluate(`pgAutomationReferenceItems(["${mode}"],{})`)[0]);
const drift = item => {
 context.__item = item;
 return evaluate('pgAutomationTemplateDrift(__item)');
};
// Values come back from the vm realm, where Array.prototype is not this
// realm's, so a strict deep compare fails on identical contents. Marshal first.
const fields = item => clone((drift(item) || []).map(d => d.field).sort());

// --- a pristine job is not drifted ---
for (const mode of ['sdr-filmmaker','sdr-cinema','hdr-filmmaker','dv-filmmaker']) {
 assert.equal(drift(build(mode)), null, mode + ' straight from the template reports no drift');
}

// --- a JSON round trip is not drift ---
// A job that came back from the Pi has been encoded and decoded twice: booleans
// arrive as 0/1 and numbers can arrive as strings. Comparing raw values would
// report every boolean on every job, which is the noise this must not produce.
{
 const job = build('sdr-filmmaker');
 job.calibration.dark_detail = 1;
 job.calibration.lattice_residuals = 1;
 job.settings.contrast = '85';
 job.target_delta_e = '0.5';
 job.panel_light.fixed_value = '95';
 assert.equal(drift(job), null, 'booleans as 0/1 and numbers as strings are not drift');
}

// --- the real incident ---
{
 const job = build('sdr-filmmaker');
 job.calibration.dark_detail = false;
 job.calibration.solve_cube_size = 17;
 assert.deepEqual(fields(job), ['calibration.dark_detail','calibration.solve_cube_size'],
  'the job that calibrated with Dark Detail off and a 17-node solve is reported, and only those fields');
 const one = drift(job).find(d => d.field === 'calibration.dark_detail');
 assert.equal(one.was, true, 'the badge names what the template said');
 assert.equal(one.now, false, 'and what the job carries');
}

// --- a changed TV setting is drift, including one added or removed ---
{
 const job = build('sdr-filmmaker');
 job.settings.backlight = 42;
 assert.deepEqual(fields(job), ['settings.backlight'], 'a changed panel light setting is reported');
 const gone = build('sdr-filmmaker');
 delete gone.settings.contrast;
 assert.deepEqual(fields(gone), ['settings.contrast'], 'a dropped TV control is reported too');
}

// --- a measured value written back by the runner is NOT drift ---
// A finished SDR job carries the luminance the runner measured (31.99 against
// the template's 100), and "Copy this run to an editable queue" puts that item
// straight back on the queue. Badging it would flag a job nobody touched.
{
 const job = build('sdr-filmmaker');
 job.target_luminance = 31.987467;
 job.calibration.target_luminance = 31.987467;
 assert.equal(drift(job), null, 'the runner-measured luminance is not reported as an edit');
 job.panel_light.fixed_value = 42;
 assert.deepEqual(fields(job), ['panel_light.fixed_value'],
  'but the panel light that actually drives it still is');
}

// --- workflow and environment are NOT drift ---
// Opting a job into extra sweeps, renaming it, or running it against a
// different meter correction are all legitimate. A badge that fires on those
// would be ignored, and then it would not be read when it mattered.
{
 const job = build('sdr-filmmaker');
 job.stages.post_readings = true;
 job.stages.pre_readings = true;
 job.name = 'SDR Filmmaker (mine)';
 job.ccss_override = 'someone-elses.ccss';
 job.refresh_rate = '60';
 job.pre_series = [];
 assert.equal(drift(job), null, 'stages, name, meter correction, refresh rate and series are not drift');
}

// --- a job with nothing to compare against ---
{
 const job = build('sdr-filmmaker');
 delete job.template_mode;
 assert.equal(drift(job), null, 'a job with no template_mode reports nothing rather than guessing');
 const hand = build('sdr-filmmaker');
 hand.template_id = '';
 assert.equal(drift(hand), null, 'a hand-built job is not measured against a template it never had');
 const older = build('sdr-filmmaker');
 older.template_id = 'reference-settings-v3';
 older.calibration.dark_detail = false;
 assert.ok(drift(older), 'an earlier reference version is still compared');
}

// --- the badge itself ---
{
 context.__item = build('sdr-filmmaker');
 assert.equal(evaluate('pgAutomationDriftBadge(__item)'), '', 'a clean job renders no badge');
 const job = build('sdr-filmmaker');
 job.calibration.dark_detail = false;
 context.__item = job;
 const badge = evaluate('pgAutomationDriftBadge(__item)');
 // "Differs from" is one stem shared by the template and recipe badges: it is
 // accurate whether the job was edited or the reference moved underneath it.
 assert.match(badge, /Differs from reference · 1 field</, 'one field is singular');
 assert.match(badge, /title="[^"]*dark_detail/, 'the differing field is named on hover');
 job.calibration.solve_cube_size = 17;
 context.__item = job;
 assert.match(evaluate('pgAutomationDriftBadge(__item)'), /· 2 fields</, 'two fields is plural');
}

// --- the badge cannot inject markup ---
{
 const job = build('sdr-filmmaker');
 job.template_mode = 'sdr-filmmaker" onmouseover="alert(1)';
 job.calibration.dark_detail = false;
 context.__item = job;
 const badge = evaluate('pgAutomationDriftBadge(__item)');
 assert.ok(!/onmouseover="alert/.test(badge), 'a hostile template_mode is escaped, not rendered');
}

// --- provenance: jobs added from a saved recipe ---
// A job built by "Add job" or added from a recipe carries no template_id, so
// the reference branch above cannot badge it -- including the job behind the
// original incident. Stamping source_recipe at add time gives the badge a
// reference to compare against: the recipe as it stands now.
//
// Build recipes inside the vm realm so the reference the resolver reads back
// belongs to the same realm as the job under test.
const setRecipes = recipes => evaluate('pgAutomation.recipes = ' + JSON.stringify(recipes));
const recipeFrom = (mode, extra) => Object.assign(build(mode), extra);

// A job added from a recipe and left untouched matches it: no badge.
{
 const recipe = recipeFrom('sdr-filmmaker', {id:'r1', name:'My SDR'});
 setRecipes([recipe]);
 const job = clone(recipe);
 job.source_recipe = 'r1';
 assert.equal(drift(job), null, 'a job added from a recipe and untouched reports no drift');
}

// An edited recipe job reports exactly the fields that were changed.
{
 const recipe = recipeFrom('sdr-filmmaker', {id:'r1', name:'My SDR'});
 setRecipes([recipe]);
 const job = clone(recipe);
 job.source_recipe = 'r1';
 job.calibration.dark_detail = false;
 job.settings.backlight = 42;
 assert.deepEqual(fields(job), ['calibration.dark_detail','settings.backlight'],
  'a job edited after being added from a recipe reports exactly the edited fields');
}

// A recipe deleted after the job was queued leaves the job with no reference.
{
 const recipe = recipeFrom('sdr-filmmaker', {id:'r1', name:'My SDR'});
 setRecipes([recipe]);
 const job = clone(recipe);
 job.source_recipe = 'gone';
 job.calibration.dark_detail = false;
 assert.equal(drift(job), null, 'a job whose recipe was deleted reports nothing rather than a badge with no reference');
}

// source_recipe is proximate provenance and wins over template_id. The recipe
// here was itself widened to a 17-node solve; a job added from it and left
// untouched matches the recipe, so it reports nothing -- even though it still
// differs from the bare reference the recipe descends from. Were the template
// consulted instead, that 17 vs 33 would be reported.
{
 const recipe = recipeFrom('sdr-filmmaker', {id:'r1', name:'Wide solve'});
 recipe.calibration.solve_cube_size = 17;
 setRecipes([recipe]);
 const job = clone(recipe);
 job.source_recipe = 'r1';
 assert.equal(drift(job), null, 'source_recipe wins over template_id: compared against the recipe, not the reference it descends from');
}

// Saving a queue item as a new recipe must not carry its source_recipe: a
// recipe is a source, not a derivative, and a saved recipe claiming to descend
// from another recipe would badge every job added from it.
{
 context.__item = {id:'x', name:'From queue', source_recipe:'r1', settings:{}};
 const saved = clone(evaluate('pgAutomationRecipeForSave(__item, false)'));
 assert.ok(!('source_recipe' in saved), 'a queue item saved as a new recipe drops its source_recipe');
 assert.ok(!('id' in saved), 'and drops the id so the server assigns a fresh one');
 const edited = clone(evaluate('pgAutomationRecipeForSave(__item, true)'));
 assert.ok(!('source_recipe' in edited), 'editing an existing recipe drops source_recipe too');
 assert.equal(edited.id, 'x', 'but keeps the id it is updating');
}

// The recipe name flows into the badge title, so a hostile name must be
// escaped. Unlike the template_mode case above -- where a hostile mode never
// resolves and the badge is empty -- a recipe is found by id, so the badge
// renders and this genuinely exercises the escaping.
{
 const recipe = recipeFrom('sdr-filmmaker', {id:'r1', name:'Nasty" onmouseover="alert(1)'});
 setRecipes([recipe]);
 const job = clone(recipe);
 job.source_recipe = 'r1';
 job.calibration.dark_detail = false;
 context.__item = job;
 const badge = evaluate('pgAutomationDriftBadge(__item)');
 assert.match(badge, /Differs from recipe · 1 field</, 'a drifted recipe job renders a recipe badge');
 assert.ok(!/onmouseover="alert/.test(badge), 'a hostile recipe name is escaped, not rendered');
}

console.log('ok');
