import { normalizeQuery, matchesQuery, filterIssues, sortByPriority, readSavedState } from './logic.js';

const issues = [
  { id: 'PB-248', title: 'Mobile checkout loses delivery address', owner: 'Maya Chen', priority: 'high', status: 'open' },
  { id: 'PB-244', title: 'Usage chart timezone mismatch', owner: 'Leo Martin', priority: 'medium', status: 'in-progress' },
  { id: 'PB-239', title: 'Keyboard focus trapped in modal', owner: 'Nora Bell', priority: 'high', status: 'resolved' },
  { id: 'PB-235', title: 'Exported CSV misses owner column', owner: 'Ishan Rao', priority: 'low', status: 'open' },
  { id: 'PB-229', title: 'Team filter resets after refresh', owner: 'Maya Chen', priority: 'medium', status: 'in-progress' },
  { id: 'PB-221', title: 'Avatar fallback has poor contrast', owner: 'Nora Bell', priority: 'low', status: 'resolved' }
];

const defaults = { filter: 'all', query: '' };
let state = { ...defaults, ...readSavedState(localStorage.getItem('pulseboard-state')) };
const list = document.querySelector('#issue-list');
const empty = document.querySelector('#empty-state');
const search = document.querySelector('#issue-search');
const filters = document.querySelector('#status-filters');
const menuButton = document.querySelector('#menu-toggle');
const sidebar = document.querySelector('#sidebar');
const overlay = document.querySelector('#overlay');

function label(value) { return value.replace('-', ' ').replace(/^./, (char) => char.toUpperCase()); }
function render() {
  search.value = state.query;
  const query = normalizeQuery(state.query);
  const visible = sortByPriority(filterIssues(issues, state.filter).filter((issue) => matchesQuery(issue, query)));
  list.innerHTML = visible.map((issue) => `<article class="issue"><div class="priority ${issue.priority}"></div><div><span class="issue-id">${issue.id}</span><h3>${issue.title}</h3></div><span class="owner">${issue.owner}</span><span class="state state-${issue.status}">${label(issue.status)}</span></article>`).join('');
  empty.hidden = visible.length !== 0;
  filters.querySelectorAll('button').forEach((button) => button.setAttribute('aria-pressed', String(button.dataset.filter === state.filter)));
}
function save() { localStorage.setItem('pulseboard-state', JSON.stringify(state)); }
search.addEventListener('input', () => { state.query = search.value; save(); render(); });
filters.addEventListener('click', (event) => { if (!event.target.matches('button')) return; state.filter = event.target.dataset.filter; save(); render(); });
menuButton.addEventListener('click', () => { sidebar.classList.toggle('open'); overlay.hidden = !overlay.hidden; });
document.querySelector('#open-count').textContent = issues.filter((item) => item.status === 'open').length;
document.querySelector('#progress-count').textContent = issues.filter((item) => item.status === 'in-progress').length;
document.querySelector('#resolved-count').textContent = issues.filter((item) => item.status === 'resolved').length;
render();
