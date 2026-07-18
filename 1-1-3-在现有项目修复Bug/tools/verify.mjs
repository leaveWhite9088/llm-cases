import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';

const target = process.argv[2];
const results = [];
function check(name, fn) { try { fn(); results.push({ name, passed: true }); } catch (error) { results.push({ name, passed: false, detail: error.message }); } }
function equal(actual, expected) { if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`); }
let mod;
try { const source = await readFile(resolve(target), 'utf8'); mod = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`); } catch (error) { process.stdout.write(JSON.stringify({ results:[{name:'logic module loads',passed:false,detail:error.message}] })); process.exit(1); }
const sample = [
  { id:'1', title:'Export CSV', owner:'Maya Chen', status:'open', priority:'low' },
  { id:'2', title:'Mobile Checkout', owner:'Leo Martin', status:'resolved', priority:'high' },
  { id:'3', title:'Chart labels', owner:'Nora Bell', status:'open', priority:'medium' }
];
check('normalize trims and lowercases',()=>equal(mod.normalizeQuery('  MoBiLE  '),'mobile'));
check('query matches title case-insensitively',()=>equal(mod.matchesQuery(sample[1],'mobile'),true));
check('query matches owner',()=>equal(mod.matchesQuery(sample[0],'maya'),true));
check('empty query matches',()=>equal(mod.matchesQuery(sample[0],''),true));
check('all filter returns all',()=>equal(mod.filterIssues(sample,'all').map(x=>x.id),['1','2','3']));
check('status filter is exact',()=>equal(mod.filterIssues(sample,'open').map(x=>x.id),['1','3']));
check('priority order high-medium-low',()=>equal(mod.sortByPriority(sample.map(item=>({...item}))).map(x=>x.priority),['high','medium','low']));
check('priority sort is immutable',()=>{ const input=sample.map(item=>({...item})); const before=input.map(x=>x.id); mod.sortByPriority(input); equal(input.map(x=>x.id),before); });
check('missing state falls back',()=>equal(mod.readSavedState(null),{filter:'all',query:''}));
check('corrupt state falls back',()=>equal(mod.readSavedState('{bad'),{filter:'all',query:''}));
check('invalid fields are sanitized',()=>equal(mod.readSavedState('{"filter":"wat","query":42}'),{filter:'all',query:''}));
check('valid state is accepted',()=>equal(mod.readSavedState('{"filter":"resolved","query":"maya"}'),{filter:'resolved',query:'maya'}));
process.stdout.write(JSON.stringify({ results }));
process.exit(results.every(item=>item.passed)?0:1);
