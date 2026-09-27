const state = { services: [], clients: [], jobs: [], selectedJob: null, quote: null };
const $ = (selector) => document.querySelector(selector);
const money = (value, currency = 'COP') => new Intl.NumberFormat('es-CO', { style: 'currency', currency, maximumFractionDigits: 0 }).format(Number(value || 0));
const escapeHtml = (text) => String(text ?? '').replace(/[&<>'"]/g, char => ({ '&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;' }[char]));

async function api(path, options = {}) {
  const response = await fetch(path, { headers: { 'Content-Type': 'application/json', ...(options.headers || {}) }, ...options });
  const body = await response.json().catch(() => ({ ok: false, message: 'Respuesta inválida del servidor' }));
  if (!response.ok || body.ok === false) throw new Error(body.message || body.error || 'La operación no se pudo completar');
  return body;
}
function toast(message, error = false) { const node = $('#toast'); node.textContent = message; node.className = `toast show${error ? ' error' : ''}`; clearTimeout(toast.timer); toast.timer = setTimeout(() => node.className = 'toast', 3800); }
function badge(value) { return `<span class="badge ${escapeHtml(value)}">${escapeHtml(String(value).replaceAll('_', ' '))}</span>`; }
function selectedService(id) { return state.services.find(service => service.id === id); }

function populateServices() {
  const options = state.services.filter(service => service.id !== 'simulate-service').map(service => `<option value="${escapeHtml(service.id)}">${escapeHtml(service.name)} · desde ${money(service.base_price)}</option>`).join('');
  $('#requestService').innerHTML = `<option value="">Selecciona un servicio</option>${options}`;
  $('#quoteService').innerHTML = options;
  renderAddons();
}
function populateClients() {
  $('#requestClient').innerHTML = `<option value="">Crear un cliente nuevo</option>${state.clients.map(client => `<option value="${escapeHtml(client.id)}">${escapeHtml(client.name)}${client.contact ? ` · ${escapeHtml(client.contact)}` : ''}</option>`).join('')}`;
}
function renderAddons() {
  const service = selectedService($('#quoteService').value);
  const entries = Object.entries(service?.addons || {});
  $('#quoteAddons').innerHTML = entries.length ? entries.map(([id, addon]) => `<label class="addon"><input type="checkbox" value="${escapeHtml(id)}" />${escapeHtml(addon.name)} · ${money(addon.price)}</label>`).join('') : '<small>Este servicio no tiene extras configurados.</small>';
  const label = service?.pricing?.unitLabel || 'unidad';
  $('#quoteUnits').previousElementSibling.textContent = `Cantidad (${label})`;
}
function renderQuote(quote) {
  state.quote = quote;
  $('#quoteResult').className = 'quote-result';
  $('#quoteResult').innerHTML = `<div class="quote-total"><div><small>TOTAL ESTIMADO</small><strong>${money(quote.total, quote.currency)}</strong></div><div style="text-align:right"><small>${escapeHtml(quote.complexity)} · ${quote.units} ${escapeHtml(quote.unit_label)}${quote.units !== 1 ? 's' : ''}</small><small>${quote.estimated_hours} h estimadas</small></div></div><span class="quote-breakdown">Base ${money(quote.base_price, quote.currency)} · Volumen ${money(quote.volume_total, quote.currency)} · Complejidad ${money(quote.complexity_amount, quote.currency)} · Extras ${money(quote.addons_total, quote.currency)}${quote.discount_amount ? ` · Descuento −${money(quote.discount_amount, quote.currency)}` : ''}</span>`;
}
function renderDashboard(dashboard) {
  $('#metricClients').textContent = dashboard.clients;
  $('#metricJobs').textContent = dashboard.jobs;
  $('#metricPayments').textContent = dashboard.pending_payment;
  $('#metricDelivered').textContent = dashboard.delivered;
}
function renderJobs() {
  $('#jobsCount').textContent = state.jobs.length;
  const rows = state.jobs.map(job => `<tr><td><span class="job-id">${escapeHtml(job.id)}</span><span class="job-desc">${escapeHtml(job.description || 'Sin descripción')}</span></td><td>${escapeHtml(job.client_name || job.client_id)}</td><td>${escapeHtml(job.service)}</td><td>${badge(job.state)}</td><td>${badge(job.payment_status)}</td><td><button type="button" class="table-action" data-job="${escapeHtml(job.id)}">Abrir</button></td></tr>`).join('');
  $('#jobsTable').innerHTML = rows || '<tr><td colspan="6" class="loading">Todavía no hay pedidos registrados.</td></tr>';
  document.querySelectorAll('[data-job]').forEach(button => button.addEventListener('click', () => selectJob(button.dataset.job)));
}
async function load() {
  try {
    const [services, clients, jobs, dashboard] = await Promise.all([api('/api/services'), api('/api/clients'), api('/api/jobs'), api('/api/dashboard')]);
    state.services = services.services; state.clients = clients.clients; state.jobs = jobs.jobs;
    populateServices(); populateClients(); renderJobs(); renderDashboard(dashboard.dashboard);
    if (state.selectedJob) { const current = state.jobs.find(job => job.id === state.selectedJob.id); if (current) await selectJob(current.id, true); }
  } catch (error) { toast(error.message, true); }
}
async function calculateQuote(event) {
  if (event) event.preventDefault();
  try {
    const addons = [...document.querySelectorAll('#quoteAddons input:checked')].map(input => input.value);
    const result = await api('/api/quotes', { method: 'POST', body: JSON.stringify({ serviceId: $('#quoteService').value, units: $('#quoteUnits').value, complexity: $('#quoteComplexity').value, discountPct: $('#quoteDiscount').value, addons }) });
    renderQuote(result.quote);
  } catch (error) { toast(error.message, true); }
}
async function createRequest(event) {
  event.preventDefault();
  try {
    const result = await api('/api/requests', { method: 'POST', body: JSON.stringify({ clientId: $('#requestClient').value, clientName: $('#clientName').value.trim(), contact: $('#clientContact').value.trim(), service: $('#requestService').value, description: $('#requestDescription').value.trim() }) });
    toast(`Pedido ${result.job.id} creado correctamente.`);
    event.target.reset();
    $('#requestClient').value = ''; await load(); await selectJob(result.job.id);
    document.querySelector('#jobs').scrollIntoView({ behavior: 'smooth', block: 'start' });
  } catch (error) { toast(error.message, true); }
}
function setWordTestResult(message, type = '') {
  const node = $('#wordTestResult');
  node.className = `word-test-result show ${type}`;
  node.innerHTML = message;
}
async function runWordTest(event) {
  event.preventDefault();
  const submit = $('#wordTestSubmit');
  try {
    const file = await formFileAsBase64($('#wordTestFile'));
    if (!file) throw new Error('Selecciona un archivo .md o .txt antes de continuar');
    submit.disabled = true;
    setWordTestResult('Procesando con Ollama local, generando el DOCX y ejecutando control de calidad. Puede tardar un momento.', 'pending');
    const result = await api('/api/word-tests', { method: 'POST', body: JSON.stringify({ ...file, title: $('#wordTestTitle').value.trim() }) });
    const test = result.test;
    setWordTestResult(`Prueba completada: estado <strong>${escapeHtml(test.state)}</strong>, QA <strong>${escapeHtml(test.qa)}</strong>. El documento temporal vence el ${escapeHtml(new Date(test.expires_at).toLocaleString('es-CO'))}.<br><a href="${escapeHtml(test.download_url)}">Descargar documento Word (.docx)</a>`, 'success');
    toast('Documento Word de prueba generado correctamente.');
    await load();
  } catch (error) {
    setWordTestResult(escapeHtml(error.message), 'error');
    toast(error.message, true);
  } finally {
    submit.disabled = false;
  }
}
function showWizardStage(selector, markup) {
  const node = $(selector); node.className = 'wizard-stage show'; node.innerHTML = markup;
}
function wizardList(items) {
  const list = Array.isArray(items) ? items : [];
  return list.length ? `<ul>${list.map(item => `<li>${escapeHtml(item)}</li>`).join('')}</ul>` : '<p>No se detectaron elementos adicionales.</p>';
}
function renderWizardAnalysis(analysis) {
  const plan = analysis.plan;
  state.wizard = { sessionId: analysis.session_id, plan, draft: '' };
  showWizardStage('#wizardAnalysis', `<h3>2. Solicitud analizada</h3><div class="wizard-analysis-grid"><div class="wizard-analysis-card"><strong>Tipo de documento</strong><p>${escapeHtml(plan.document_type)}</p></div><div class="wizard-analysis-card"><strong>Título sugerido</strong><p>${escapeHtml(plan.title)}</p></div><div class="wizard-analysis-card full"><strong>Resumen</strong><p>${escapeHtml(plan.summary)}</p></div><div class="wizard-analysis-card"><strong>Actividades detectadas</strong>${wizardList(plan.tasks)}</div><div class="wizard-analysis-card"><strong>Secciones sugeridas</strong>${wizardList(plan.suggested_sections)}</div></div>`);
  const fields = (plan.clarifying_questions || []).map(question => `<label class="wizard-question"><span>${escapeHtml(question.question)}</span>${question.help ? `<small>${escapeHtml(question.help)}</small>` : ''}<textarea rows="4" data-wizard-question="${escapeHtml(question.id)}" maxlength="8000" required placeholder="Escribe la respuesta confirmada por el cliente."></textarea></label>`).join('');
  showWizardStage('#wizardAnswersForm', `<h3>3. Responde las preguntas del cliente</h3><p>Estas respuestas son la base del contenido. Lo que no se confirme se marcará como pendiente; el asistente no debe inventar datos.</p>${fields}<div class="wizard-actions"><button id="wizardDraftSubmit" class="primary" type="submit">Generar borrador para revisión <span>→</span></button><span id="wizardAnswersStatus" class="wizard-status"></span></div>`);
  $('#wizardAnswersForm').onsubmit = generateWizardDraft;
  $('#wizardDraftForm').className = 'wizard-stage'; $('#wizardDraftForm').innerHTML = '';
  document.querySelector('#wizardAnswersForm').scrollIntoView({ behavior: 'smooth', block: 'start' });
}
async function analyzeWordWizard(event) {
  event.preventDefault();
  const submit = $('#wizardAnalyzeSubmit');
  try {
    const file = await formFileAsBase64($('#wizardFile'));
    if (!file) throw new Error('Selecciona la solicitud del cliente en formato .md o .txt');
    submit.disabled = true;
    showWizardStage('#wizardAnalysis', '<h3>2. Analizando la solicitud</h3><p>Ollama local está identificando actividades, estructura y datos que se deben confirmar.</p>');
    $('#wizardAnswersForm').className = 'wizard-stage'; $('#wizardDraftForm').className = 'wizard-stage';
    const result = await api('/api/word-wizard/analyze', { method: 'POST', body: JSON.stringify({ ...file, title: $('#wizardTitle').value.trim() }) });
    renderWizardAnalysis(result.analysis);
    toast('Solicitud analizada. Completa las preguntas para crear el borrador.');
  } catch (error) {
    showWizardStage('#wizardAnalysis', `<h3>La solicitud no se pudo analizar</h3><p class="wizard-status error">${escapeHtml(error.message)}</p>`);
    toast(error.message, true);
  } finally {
    submit.disabled = false;
  }
}
async function generateWizardDraft(event) {
  event.preventDefault();
  if (!state.wizard) return;
  const submit = $('#wizardDraftSubmit');
  try {
    const answers = [...document.querySelectorAll('[data-wizard-question]')].map(input => ({ id: input.dataset.wizardQuestion, answer: input.value.trim() }));
    submit.disabled = true; $('#wizardAnswersStatus').textContent = 'Redactando el borrador con Ollama local…';
    const result = await api('/api/word-wizard/draft', { method: 'POST', body: JSON.stringify({ sessionId: state.wizard.sessionId, answers }) });
    state.wizard.draft = result.draft.draft;
    showWizardStage('#wizardDraftForm', `<h3>4. Revisa y edita el borrador</h3><p>Comprueba nombres, datos, actividades y afirmaciones antes de generar el Word. Puedes editar directamente el texto.</p><textarea id="wizardDraftContent" class="wizard-draft" maxlength="200000">${escapeHtml(result.draft.draft)}</textarea><div class="wizard-actions"><button id="wizardDeliverSubmit" class="primary" type="submit">Generar Word revisado <span>→</span></button><span id="wizardDeliveryStatus" class="wizard-status">Esta salida es una prueba local aislada; no crea un cobro comercial.</span></div>`);
    $('#wizardDraftForm').onsubmit = deliverWordWizard;
    document.querySelector('#wizardDraftForm').scrollIntoView({ behavior: 'smooth', block: 'start' });
    toast('Borrador creado. Revísalo antes de generar el Word.');
  } catch (error) {
    $('#wizardAnswersStatus').textContent = error.message; $('#wizardAnswersStatus').className = 'wizard-status error';
    toast(error.message, true);
  } finally {
    submit.disabled = false;
  }
}
async function deliverWordWizard(event) {
  event.preventDefault();
  if (!state.wizard) return;
  const submit = $('#wizardDeliverSubmit');
  const status = $('#wizardDeliveryStatus');
  try {
    submit.disabled = true; status.className = 'wizard-status'; status.textContent = 'Validando requisitos, generando DOCX y ejecutando QA…';
    const result = await api('/api/word-wizard/deliver', { method: 'POST', body: JSON.stringify({ sessionId: state.wizard.sessionId, draft: $('#wizardDraftContent').value.trim() }) });
    const delivery = result.delivery;
    status.innerHTML = `Listo: <strong>${escapeHtml(delivery.state)}</strong>, QA <strong>${escapeHtml(delivery.qa)}</strong>. <a href="${escapeHtml(delivery.download_url)}">Descargar documento Word (.docx)</a>`;
    toast('Documento Word generado y validado.');
    await load();
  } catch (error) {
    status.textContent = error.message; status.className = 'wizard-status error';
    toast(error.message, true);
  } finally {
    submit.disabled = false;
  }
}
function formFileAsBase64(input) {
  const file = input.files?.[0];
  if (!file) return Promise.resolve(null);
  return new Promise((resolve, reject) => { const reader = new FileReader(); reader.onerror = () => reject(new Error('No se pudo leer el archivo')); reader.onload = () => resolve({ fileName: file.name, contentBase64: String(reader.result).split(',').pop() }); reader.readAsDataURL(file); });
}
async function selectJob(id, quiet = false) {
  const job = state.jobs.find(item => item.id === id); if (!job) return;
  state.selectedJob = job;
  let payments = [];
  try { payments = (await api(`/api/payments?jobId=${encodeURIComponent(id)}`)).payments; } catch (error) { if (!quiet) toast(error.message, true); }
  const payment = payments[payments.length - 1];
  const paymentMarkup = payment ? `<div class="pay-info"><strong>${escapeHtml(payment.id)}</strong> · ${badge(payment.status)}<br>${money(payment.quote.amount, payment.quote.currency)} · ${escapeHtml(payment.method.name)}<br><span>${escapeHtml(payment.method.instructions || 'Sin instrucciones registradas')}</span></div>` : '<p class="pay-info">No hay solicitud de pago. Analiza primero los requisitos y configura un método de pago local.</p>';
  $('#jobDetail').className = 'panel detail-panel';
  $('#jobDetail').innerHTML = `<div class="detail-title"><div><p class="eyebrow">${escapeHtml(job.service)}</p><h3>${escapeHtml(job.id)} · ${escapeHtml(job.client_name || job.client_id)}</h3><p>${escapeHtml(job.description || 'Sin descripción')}</p></div>${badge(job.state)}</div>
    <div class="detail-block"><h4>1. REQUISITOS</h4><textarea id="requirementsText" placeholder="Solicitud del cliente">${escapeHtml(job.description || '')}</textarea><div class="detail-row"><button type="button" class="secondary mini" id="requirementsBtn">Analizar con Ollama</button></div><p>Extrae una especificación estructurada. Requiere Ollama local activo.</p></div>
    <div class="detail-block"><h4>2. ARCHIVOS DE ENTRADA</h4><label class="file-label">⌁ Adjuntar guía, datos o archivo de trabajo<input id="jobInputFile" type="file" /></label><p>Máximo 25 MB por archivo. Se guarda dentro del workspace del trabajo.</p></div>
    <div class="detail-block"><h4>3. SOLICITAR PAGO</h4><div class="detail-row"><select id="paymentMethod"><option value="nequi">Nequi</option><option value="bank-transfer">Transferencia</option></select><select id="paymentComplexity"><option value="basic">Básica</option><option value="standard" selected>Estándar</option><option value="advanced">Avanzada</option><option value="expert">Experta</option></select></div><div class="detail-row"><input id="paymentUnits" type="number" min="1" value="1" /><button type="button" class="secondary mini" id="paymentRequestBtn">Solicitar pago</button></div>${paymentMarkup}</div>
    <div class="detail-block"><h4>4. COMPROBANTE Y APROBACIÓN</h4><label class="file-label">⌾ Subir comprobante (.png, .jpg o .pdf)<input id="paymentProofFile" type="file" accept=".png,.jpg,.jpeg,.pdf" /></label><input id="paymentReference" style="margin-top:7px" maxlength="160" placeholder="Referencia de pago (opcional)" /><div class="detail-row"><button type="button" class="secondary mini" id="paymentProofBtn">Registrar comprobante</button><button type="button" class="primary mini" id="paymentApproveBtn">Aprobar pago</button></div></div>`;
  $('#requirementsBtn').onclick = () => analyzeRequirements(job.id);
  $('#jobInputFile').onchange = () => uploadInput(job.id);
  $('#paymentRequestBtn').onclick = () => requestPayment(job.id);
  $('#paymentProofBtn').onclick = () => uploadProof(job.id);
  $('#paymentApproveBtn').onclick = () => approvePayment(job.id);
}
async function analyzeRequirements(jobId) {
  try { const result = await api(`/api/jobs/${encodeURIComponent(jobId)}/requirements`, { method: 'POST', body: JSON.stringify({ request: $('#requirementsText').value.trim() }) }); toast(result.ok ? 'Requisitos extraídos. El trabajo está listo para cotizar.' : result.error, !result.ok); await load(); } catch (error) { toast(error.message, true); }
}
async function uploadInput(jobId) {
  try { const file = await formFileAsBase64($('#jobInputFile')); if (!file) return; await api(`/api/jobs/${encodeURIComponent(jobId)}/input`, { method: 'POST', body: JSON.stringify(file) }); toast('Archivo adjuntado al trabajo.'); } catch (error) { toast(error.message, true); }
}
async function requestPayment(jobId) {
  try { const result = await api('/api/payments/request', { method: 'POST', body: JSON.stringify({ jobId, method: $('#paymentMethod').value, complexity: $('#paymentComplexity').value, units: $('#paymentUnits').value, addons: [] }) }); toast(`Pago ${result.payment.id} solicitado por ${money(result.payment.quote.amount, result.payment.quote.currency)}.`); await load(); } catch (error) { toast(error.message, true); }
}
async function uploadProof(jobId) {
  try { const file = await formFileAsBase64($('#paymentProofFile')); if (!file) throw new Error('Selecciona un comprobante antes de continuar'); file.jobId = jobId; file.reference = $('#paymentReference').value.trim(); await api('/api/payments/proof', { method: 'POST', body: JSON.stringify(file) }); toast('Comprobante recibido. Revisa el valor antes de aprobarlo.'); await load(); } catch (error) { toast(error.message, true); }
}
async function approvePayment(jobId) {
  try { const result = await api('/api/payments/approve', { method: 'POST', body: JSON.stringify({ jobId, by: 'operador-web' }) }); toast(`Pago ${result.payment.id} aprobado. La producción ya puede iniciar.`); await load(); } catch (error) { toast(error.message, true); }
}

$('#refreshBtn').addEventListener('click', load);
$('#wizardAnalyzeForm').addEventListener('submit', analyzeWordWizard);
$('#wordTestForm').addEventListener('submit', runWordTest);
$('#requestForm').addEventListener('submit', createRequest);
$('#quoteForm').addEventListener('submit', calculateQuote);
$('#quoteService').addEventListener('change', renderAddons);
$('#requestClient').addEventListener('change', event => { const existing = state.clients.find(client => client.id === event.target.value); $('#clientName').disabled = Boolean(existing); $('#clientContact').disabled = Boolean(existing); if (existing) { $('#clientName').value = existing.name; $('#clientContact').value = existing.contact || ''; } else { $('#clientName').value = ''; $('#clientContact').value = ''; } });
load();