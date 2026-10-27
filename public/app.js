const $ = id => document.getElementById(id);
const token = document.querySelector('meta[name="api-token"]').content;
let records = [];
function id() { const n = Number($('applicant').value); if (!Number.isInteger(n) || n < 1) throw new Error('Enter a positive applicant ID.'); return n; }
function message(text, error = false) { $('message').textContent = text; $('message').className = error ? 'error' : ''; }
async function request(path, options = {}) {
  const res = await fetch(path, { ...options, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}`, ...options.headers } });
  const data = await res.json();
  if (!res.ok) throw new Error(data.error || 'Request failed.');
  return { res, data };
}
async function health() {
  try {
    const { data } = await request('/health');
    $('health').textContent = `SQL ready · Redis ${data.redis}`;
    $('ttl').textContent = data.cache_ttl_seconds;
    const { data: metrics } = await request('/api/metrics');
    $('queries').textContent = metrics.sqlCountQueries;
  } catch (e) { $('health').textContent = 'API or database unavailable'; }
}
async function read() {
  const start = performance.now();
  const { res, data } = await request(`/api/applicants/${id()}/application-count`);
  const duration = (performance.now() - start).toFixed(1);
  const source = res.headers.get('X-Cache');
  $('name').textContent = data.full_name;
  $('count').textContent = data.application_count;
  $('source').textContent = source;
  $('duration').textContent = `${duration} ms`;
  $('response').textContent = JSON.stringify({ status: res.status, 'X-Cache': source, 'X-Cache-Key': res.headers.get('X-Cache-Key'), body: data }, null, 2);
  records.unshift({ time: new Date().toLocaleTimeString(), source, count: data.application_count, duration });
  $('history').replaceChildren(...records.slice(0, 12).map(row => {
    const tr = document.createElement('tr');
    for (const value of [row.time, row.source, String(row.count), `${row.duration} ms`]) {
      const td = document.createElement('td');
      if (value === row.source) { const span = document.createElement('span'); span.className = `badge ${row.source}`; span.textContent = value; td.append(span); }
      else td.textContent = value;
      tr.append(td);
    }
    return tr;
  }));
  await health();
  return source;
}
async function options() {
  const { data } = await request(`/api/applicants/${id()}/options`);
  for (const [target, rows, key, label] of [['job', data.jobs, 'job_ad_id', 'title'], ['skill', data.skills, 'skill_id', 'skill_name']]) {
    $(target).replaceChildren(...rows.map(row => { const opt = document.createElement('option'); opt.value = row[key]; opt.textContent = `${row[key]} · ${row[label]}`; return opt; }));
  }
  if (!data.jobs.length || !data.skills.length) message('No unused job or skill is available for this applicant.', true);
}
async function run(fn) { try { message(''); await fn(); } catch (e) { message(e.message, true); } }
$('read').onclick = () => run(read);
$('twice').onclick = () => run(async () => { const first = await read(); const second = await read(); message(`Two requests: ${first} → ${second}`); });
$('clear').onclick = () => run(async () => { await request(`/api/applicants/${id()}/cache`, { method: 'POST', body: '{}' }); message('Cache cleared. The next request will query SQL Server.'); });
$('options').onclick = () => run(options);
$('applicant').onchange = () => { $('job').replaceChildren(); $('skill').replaceChildren(); };
$('apply').onsubmit = event => { event.preventDefault(); void run(async () => {
  const { data } = await request(`/api/applicants/${id()}/applications`, { method: 'POST', body: JSON.stringify({ job_ad_id: Number($('job').value), skill_id: Number($('skill').value) }) });
  const source = await read(); await options();
  message(`Application ${data.application_id} created. Refreshed count: ${source}.`);
}); };
void health();
