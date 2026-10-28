'use strict';
const el = id => document.getElementById(id);
const node = (tag, text, cls) => {
	const item = document.createElement(tag);
	if (text !== undefined) item.textContent = text;
	if (cls) item.className = cls;
	return item;
};
el('text').value = Array.from({length: 180}, (_, i) =>
	`${i % 11 === 0 ? 'ERROR' : i % 4 === 0 ? 'WARN' : 'INFO'} request=${i} route=/reports café cache ${i % 3 ? 'hit' : 'miss'}`
).join('\n');
async function request(path, options) {
	const response = await fetch(path, options);
	const body = await response.json();
	if (!response.ok) throw new Error(body.error || `HTTP ${response.status}`);
	return body;
}
function render(snapshot) {
	for (const key of ['active', 'completed', 'rejected']) el(key).textContent = snapshot.metrics[key];
	el('limits').textContent = `${snapshot.limits.max_active} active / ${snapshot.limits.max_history} retained`;
	el('workers').replaceChildren(...snapshot.workers.map(worker => {
		const card = node('div', `Worker ${worker.id}`, `worker${worker.job ? ' busy' : ''}`);
		card.append(node('span', worker.job ? `Job #${worker.job}` : 'Idle'));
		return card;
	}));
	const cards = snapshot.jobs.map(job => {
		const card = node('article', undefined, 'job');
		const heading = node('div', undefined, 'job-heading');
		heading.append(node('strong', `Job #${job.id}`), node('span', job.state, `state ${job.state}`));
		if (!job.terminal) {
			const cancel = node('button', 'Cancel', 'cancel');
			cancel.onclick = () => request(`/jobs/${job.id}`, {method: 'DELETE'}).catch(error => { el('notice').textContent = error.message; });
			heading.append(cancel);
		}
		const progress = node('progress');
		progress.max = job.chunks_total || 1;
		progress.value = job.terminal ? progress.max : job.chunks_done;
		const meta = node('div', undefined, 'job-meta');
		meta.append(node('span', `${job.chunks_done}/${job.chunks_total} chunks · ${job.passes} passes`), node('span', `${job.elapsed_ms.toLocaleString()} ms`));
		const totals = node('p', `${job.result.words.toLocaleString()} words · ${job.result.unique_words.toLocaleString()} distinct · ${job.result.lines.toLocaleString()} lines`, 'muted');
		const words = node('div', undefined, 'words');
		words.append(...job.result.top_words.slice(0, 10).map(word => node('span', `${word.word} ${word.count}`, 'word')));
		card.append(heading, progress, meta, totals, words);
		if (job.error) card.append(node('p', job.error, 'error'));
		return card;
	});
	el('jobs').replaceChildren(...(cards.length ? cards : [node('p', 'Your first job goes here.', 'muted')]));
}
el('submit').addEventListener('submit', async event => {
	event.preventDefault();
	const button = event.target.querySelector('button');
	button.disabled = true;
	el('notice').textContent = '';
	try {
		const job = await request('/jobs', {method: 'POST', headers: {'Content-Type': 'application/json'},
			body: JSON.stringify({text: el('text').value, passes: Number(el('passes').value)})});
		el('notice').textContent = `Queued job #${job.id}`;
	} catch (error) { el('notice').textContent = error.message; }
	finally { button.disabled = false; }
});
function connect() {
	const socket = new WebSocket(`${location.protocol === 'https:' ? 'wss:' : 'ws:'}//${location.host}/events`);
	socket.onopen = () => { el('connection').textContent = 'Connected'; };
	socket.onmessage = event => { render(JSON.parse(event.data)); };
	socket.onerror = () => socket.close();
	socket.onclose = () => { el('connection').textContent = 'Reconnecting…'; setTimeout(connect, 1000); };
}
async function health() {
	const start = performance.now();
	try { await request('/health'); el('latency').textContent = `${Math.round(performance.now() - start)} ms`; }
	catch { el('latency').textContent = 'Offline'; }
}
connect();
health();
setInterval(health, 2000);
