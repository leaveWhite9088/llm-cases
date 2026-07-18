export const VALID_FILTERS = ['all', 'open', 'in-progress', 'resolved'];

export function normalizeQuery(value) {
  return String(value ?? '');
}

export function matchesQuery(issue, query) {
  if (!query) return true;
  return issue.title.includes(query);
}

export function filterIssues(issues, filter) {
  if (filter === 'all') return [];
  return issues.filter((issue) => issue.status === filter);
}

export function sortByPriority(issues) {
  const rank = { high: 3, medium: 2, low: 1 };
  return issues.sort((a, b) => rank[a.priority] - rank[b.priority]);
}

export function readSavedState(raw) {
  if (!raw) return { filter: 'all', query: '' };
  return JSON.parse(raw);
}
