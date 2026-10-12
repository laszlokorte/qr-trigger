<script>
	import { onMount } from 'svelte';
	import jsQR from 'jsqr';
	import QRCode from 'qrcode';

	import { SvelteURL } from 'svelte/reactivity';
	const SETTINGS_KEY = 'qr-scanner-settings';
	const ENTRIES_KEY = 'qr-scanner-entries';

	let video;
	let canvas;
	let stream;
	let scanTimer;

	let scanning = $state(false);
	let cameraError = $state('');
	let showSettings = $state(false);
	let settingsScanArmed = $state(false);
	let entries = $state([]);
	let flash = $state('');

	let httpMethod = $state('GET');
	let replaceHost = $state('');
	let replacePath = $state('');
	let replaceQuery = $state('');
	let removeQuery = $state('');
	let openOnScan = $state('no');
	let proxyUrl = $state('');

	let qrDataUrl = $state('');
	const settingsUrl = $derived.by(() => {
		const params = new URLSearchParams({
			replaceHost,
			replacePath,
			replaceQuery,
			removeQuery,
			openOnScan,
			httpMethod,
			proxyUrl
		});

		return `qr-scanner://settings?${params}`;
	});
	$effect(() => {
		const url = settingsUrl;
		let cancelled = false;

		QRCode.toDataURL(url, {
			width: 220,
			margin: 2,
			errorCorrectionLevel: 'M'
		}).then((dataUrl) => {
			if (!cancelled) qrDataUrl = dataUrl;
		});

		return () => {
			cancelled = true;
		};
	});

	let lastCode = '';
	let lastSeen = 0;
	function saveSettings() {
		try {
			localStorage.setItem(SETTINGS_KEY, settingsUrl);
		} catch (error) {
			console.error('Could not save settings:', error);
		}
	}

	function restoreSettings() {
		try {
			const url = localStorage.getItem(SETTINGS_KEY);
			if (!url) return;

			// Apply the settings without logging an entry or changing the UI.
			const parsed = new URL(url);

			if (parsed.protocol !== 'qr-scanner:' || parsed.hostname !== 'settings') {
				return;
			}

			const params = parsed.searchParams;

			replaceHost = params.get('replaceHost') ?? '';
			replacePath = params.get('replacePath') ?? '';
			replaceQuery = params.get('replaceQuery') ?? '';
			removeQuery = params.get('removeQuery') ?? '';
			proxyUrl = params.get('proxyUrl') ?? '';

			const open = params.get('openOnScan');
			if (['no', 'yes', 'background'].includes(open)) {
				openOnScan = open;
			}

			const method = params.get('httpMethod');
			if (['GET', 'POST'].includes(method)) {
				httpMethod = method;
			}
		} catch (error) {
			console.error('Could not restore settings:', error);
		}
	}

	function saveEntries() {
		try {
			localStorage.setItem(ENTRIES_KEY, JSON.stringify(entries));
		} catch (error) {
			console.error('Could not save entries:', error);
		}
	}

	function restoreEntries() {
		try {
			const saved = JSON.parse(localStorage.getItem(ENTRIES_KEY) ?? '[]');

			if (!Array.isArray(saved)) return;

			entries = saved
				.filter(
					(entry) => entry && typeof entry.id === 'string' && typeof entry.original === 'string'
				)
				.map((entry) => ({
					...entry,
					time: new Date(entry.time),
					status: null,
					error: ''
				}))
				.filter((entry) => !Number.isNaN(entry.time.getTime()));
		} catch (error) {
			console.error('Could not restore entries:', error);
		}
	}
	let storageReady = $state(false);

	$effect(() => {
		if (!storageReady) return;

		saveSettings();
		saveEntries();
	});

	function parseSettingsCode(text) {
		try {
			const url = new URL(text);

			if (
				url.protocol !== 'qr-scanner:' ||
				url.hostname !== 'settings' ||
				(url.pathname !== '/' && url.pathname !== '')
			) {
				return null;
			}

			const params = url.searchParams;
			const config = {};

			for (const key of [
				'replaceHost',
				'replacePath',
				'replaceQuery',
				'removeQuery',
				'openOnScan'
			]) {
				if (params.has(key)) {
					config[key] = params.get(key);
				}
			}

			if (
				config.openOnScan !== undefined &&
				!['no', 'yes', 'background'].includes(config.openOnScan)
			) {
				return null;
			}

			return config;
		} catch {
			return null;
		}
	}

	function applySettingsCode(text) {
		const config = parseSettingsCode(text);

		if (!config) return false;

		if (config.replaceHost !== undefined) {
			replaceHost = config.replaceHost;
		}

		if (config.replacePath !== undefined) {
			replacePath = config.replacePath;
		}

		if (config.replaceQuery !== undefined) {
			replaceQuery = config.replaceQuery;
		}

		if (config.removeQuery !== undefined) {
			removeQuery = config.removeQuery;
		}

		if (config.openOnScan !== undefined) {
			openOnScan = config.openOnScan;
		}
		if (['GET', 'POST'].includes(config.httpMethod)) {
			httpMethod = config.httpMethod;
		}

		settingsScanArmed = false;
		showSettings = false;

		entries = [
			{
				id: crypto.randomUUID(),
				original: 'Settings applied',
				url: '',
				time: new Date(),
				kind: 'settings'
			},
			...entries
		];

		return true;
	}

	function rewriteUrl(text) {
		let url;

		try {
			url = new URL(text);
		} catch {
			return null;
		}

		if (!['http:', 'https:'].includes(url.protocol)) {
			return null;
		}

		if (replaceHost.trim()) {
			const host = replaceHost.trim();

			if (
				host.includes('/') ||
				host.includes('?') ||
				host.includes('#') ||
				host.includes('@') ||
				host.includes('\\')
			) {
				return null;
			}

			try {
				const parsed = new URL(`${url.protocol}//${host}`);

				if (parsed.username || parsed.password) return null;

				url.host = parsed.host;
			} catch {
				return null;
			}
		}

		if (replacePath.trim()) {
			const path = replacePath.trim();
			url.pathname = path.startsWith('/') ? path : `/${path}`;
		}

		if (replaceQuery.trim()) {
			const params = new URLSearchParams(replaceQuery.trim());

			for (const [key, value] of params) {
				url.searchParams.set(key, value);
			}
		}

		if (removeQuery.trim()) {
			const keys = removeQuery
				.split(',')
				.map((key) => key.trim())
				.filter(Boolean);

			for (const key of keys) {
				url.searchParams.delete(key);
			}
		}
		if (proxyUrl) {
			const proxy = new SvelteURL(proxyUrl);
			proxy.search = '';
			proxy.searchParams.set('url', url.href);
			return proxy.href;
		}

		return url.href;
	}

	function openUrl(url, background = false) {
		if (!url) return;

		// Foreground/background behavior is controlled by the browser.
		window.open(url, '_blank', 'noopener,noreferrer');
	}

	async function requestInBackground(entry) {
		updateEntry(entry.id, { status: 'pending', error: '' });

		const controller = new AbortController();
		const timeout = window.setTimeout(() => controller.abort(), 15000);

		try {
			const response = await fetch(entry.url, {
				method: httpMethod,
				mode: 'cors',
				credentials: 'omit',
				signal: controller.signal
			});

			if (!response.ok) {
				throw new Error(`HTTP ${response.status}`);
			}

			updateEntry(entry.id, { status: 'success' });
			flash = 'success';
		} catch (error) {
			flash = 'error';
			updateEntry(entry.id, {
				status: 'error',
				error:
					error.name === 'AbortError'
						? 'Request timed out'
						: 'Network error or CORS blocked the request'
			});
			console.error('Background request failed:', error);
		} finally {
			window.clearTimeout(timeout);

			window.setTimeout(() => {
				flash = '';
			}, 350);
		}
	}
	function updateEntry(id, updates) {
		entries = entries.map((entry) => (entry.id === id ? { ...entry, ...updates } : entry));
	}

	function handleCode(text) {
		if (settingsScanArmed) {
			applySettingsCode(text);
			return;
		}

		const url = rewriteUrl(text);

		const entry = {
			id: crypto.randomUUID(),
			original: text,
			url,
			time: new Date(),
			kind: 'url',
			status: openOnScan === 'background' && url ? 'pending' : null,
			error: ''
		};

		entries = [entry, ...entries];

		if (!url) return;

		if (openOnScan === 'yes') {
			openUrl(url);
		} else if (openOnScan === 'background') {
			requestInBackground(entry);
		}
	}

	function scanFrame() {
		if (!video || !canvas || video.readyState < 2) return;

		const width = video.videoWidth;
		const height = video.videoHeight;

		if (!width || !height) return;

		const context = canvas.getContext('2d', {
			willReadFrequently: true
		});

		canvas.width = width;
		canvas.height = height;
		context.drawImage(video, 0, 0, width, height);

		const image = context.getImageData(0, 0, width, height);

		const result = jsQR(image.data, width, height, {
			inversionAttempts: 'attemptBoth'
		});

		const now = Date.now();

		if (result?.data) {
			const text = result.data;

			// Process a code once while it remains visible.
			if (text !== lastCode || now - lastSeen > 1000) {
				handleCode(text);
				lastCode = text;
			}

			lastSeen = now;
		} else if (now - lastSeen > 1000) {
			lastCode = '';
		}
	}

	async function startCamera() {
		cameraError = '';

		try {
			if (!navigator.mediaDevices?.getUserMedia) {
				throw new Error('Camera access requires HTTPS or localhost.');
			}

			const newStream = await navigator.mediaDevices.getUserMedia({
				audio: false,
				video: {
					facingMode: { ideal: 'environment' },
					width: { ideal: 1280 },
					height: { ideal: 720 }
				}
			});

			// A camera request might complete after the component unmounts.
			if (!video) {
				newStream.getTracks().forEach((track) => track.stop());
				return;
			}

			stream = newStream;
			video.srcObject = stream;
			await video.play();
			scanning = true;
		} catch (error) {
			cameraError =
				error.name === 'NotAllowedError'
					? 'Camera access denied. Allow camera access in your browser settings.'
					: `Could not start camera: ${error.message}`;
			stopCamera();
		}
	}

	function stopCamera() {
		if (stream) {
			stream.getTracks().forEach((track) => track.stop());
			stream = null;
		}

		if (video) video.srcObject = null;

		scanning = false;
	}

	function clearEntries() {
		entries = [];
	}

	function exportSettings() {
		const url = new URL('qr-scanner://settings');

		for (const [key, value] of Object.entries({
			replaceHost,
			replacePath,
			replaceQuery,
			removeQuery,
			openOnScan
		})) {
			if (value !== '') {
				url.searchParams.set(key, value);
			}
		}

		return url.href;
	}

	async function copySettings() {
		try {
			await navigator.clipboard.writeText(exportSettings());
			cameraError = '';
		} catch {
			cameraError = 'Could not copy settings URL. Clipboard access requires HTTPS or localhost.';
		}
	}

	onMount(() => {
		restoreSettings();
		restoreEntries();
		storageReady = true;
		startCamera();

		scanTimer = window.setInterval(scanFrame, 500);

		return () => {
			window.clearInterval(scanTimer);
			stopCamera();
		};
	});
</script>

<svelte:head>
	<title>QR Scanner</title>
	<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
</svelte:head>

<div
	class="scanner"
	class:flash-success={flash === 'success'}
	class:flash-error={flash === 'error'}
>
	<video bind:this={video} autoplay muted playsinline></video>
	<canvas bind:this={canvas} class="hidden"></canvas>

	<div class="topbar">
		<div class="brand">
			<span class="dot" class:active={scanning}></span>
			QR Scanner
		</div>

		<div class="actions">
			{#if settingsScanArmed}
				<button class="cancel-settings-scan" onclick={() => (settingsScanArmed = false)}>
					Cancel settings scan
				</button>
			{:else}
				<button
					class:armed={settingsScanArmed}
					onclick={() => {
						settingsScanArmed = true;
						showSettings = false;
						lastCode = '';
					}}
				>
					{settingsScanArmed ? 'Waiting for settings QR…' : 'Scan settings'}
				</button>
			{/if}

			<button onclick={() => (showSettings = !showSettings)}> Settings </button>

			<button onclick={clearEntries}>Clear list</button>
		</div>
	</div>

	<div class="scan-frame" aria-hidden="true">
		<span></span><span></span><span></span><span></span>
	</div>

	<div class="scan-hint">
		{#if settingsScanArmed}
			Scan a qr-scanner://settings QR code
		{:else if scanning}
			Point your camera at a QR code
		{:else}
			Camera stopped
		{/if}
	</div>

	{#if cameraError}
		<div class="error">
			{cameraError}
			<button onclick={startCamera}>Retry camera</button>
		</div>
	{/if}

	{#if !scanning && !cameraError}
		<button class="start-button" onclick={startCamera}> Start camera </button>
	{/if}

	<section class="log-panel">
		<header>
			<strong>Scanned codes</strong>
			<span>{entries.length}</span>
		</header>

		{#if entries.length === 0}
			<p class="empty">Scanned URLs will appear here.</p>
		{:else}
			<ul>
				{#each entries as entry (entry.id)}
					<li>
						{#if entry.url}
							<a href={entry.url} target="_blank" rel="noopener noreferrer">
								<span class="entry-time">
									{entry.time.toLocaleTimeString()}
								</span>
								<span class="entry-url">{entry.url}</span>
								{#if entry.status === 'pending'}
									<span class="status pending">… Sending</span>
								{:else if entry.status === 'success'}
									<span class="status success">✓ Success</span>
								{:else if entry.status === 'error'}
									<span class="status failure" title={entry.error}>✕ Failed</span>
								{/if}
							</a>
						{:else}
							<div class="invalid-entry">
								<span class="entry-time">
									{entry.time.toLocaleTimeString()}
								</span>
								<span class="entry-url">
									{entry.kind === 'settings' ? entry.original : entry.original}
								</span>
							</div>
						{/if}
					</li>
				{/each}
			</ul>
		{/if}
	</section>

	{#if showSettings}
		<div
			class="backdrop"
			role="button"
			tabindex="-1"
			onkeydown={() => (showSettings = false)}
			onclick={() => (showSettings = false)}
		></div>

		<section class="settings">
			<header>
				<h2>Settings</h2>
				<button onclick={() => (showSettings = false)}>Close</button>
			</header>

			<label>
				Replace host
				<input bind:value={replaceHost} placeholder="example.com:8080" autocomplete="off" />
				<small>Leave empty to keep the original host.</small>
			</label>

			<label>
				Replace path
				<input bind:value={replacePath} placeholder="/new/path" autocomplete="off" />
				<small>Leave empty to keep the original path.</small>
			</label>

			<label>
				Replace or append query parameters
				<input bind:value={replaceQuery} placeholder="source=qr&mode=mobile" autocomplete="off" />
				<small> Format: key=value&amp;key2=value2. Existing values are replaced. </small>
			</label>

			<label>
				Remove query parameters
				<input bind:value={removeQuery} placeholder="token,debug,oldParam" autocomplete="off" />
				<small>Comma-separated parameter names.</small>
			</label>

			<label>
				Open on scan
				<select bind:value={openOnScan}>
					<option value="no">No — log only</option>
					<option value="yes">Yes — open new tab</option>
					<option value="background">Background — best effort</option>
				</select>
			</label>
			<label>
				HTTP method for background requests
				<select bind:value={httpMethod}>
					<option value="GET">GET</option>
					<option value="POST">POST</option>
				</select>
			</label>
			<label>
				Proxy URL
				<input type="url" bind:value={proxyUrl} placeholder="https://proxy.example/fetch" />
			</label>

			<div class="settings-qr">
				<h3>Settings QR Code</h3>

				{#if qrDataUrl}
					<img src={qrDataUrl} alt="QR code containing the current settings" />
				{/if}

				<button onclick={() => navigator.clipboard.writeText(settingsUrl)}>
					Copy settings URL
				</button>
				<p class="settings-note">
					Encode the copied URL as a QR code. To apply it, press "Scan settings" first and then scan
					that QR code.
				</p>
			</div>
		</section>
	{/if}
</div>

<style>
	:global(*) {
		box-sizing: border-box;
		user-select: none;
	}

	:global(body) {
		margin: 0;
		font-family: system-ui, sans-serif;
		background: #080b10;
		color: white;
	}

	:global(button),
	:global(input),
	:global(select) {
		font: inherit;
	}

	.scanner {
		position: fixed;
		inset: 0;
		overflow: hidden;
		background: #080b10;
	}

	video {
		position: absolute;
		inset: 0;
		width: 100%;
		height: 100%;
		object-fit: cover;
	}

	.hidden {
		display: none;
	}

	.topbar {
		position: absolute;
		z-index: 1;
		top: 0;
		left: 0;
		right: 0;
		padding: max(16px, env(safe-area-inset-top)) 16px 16px;
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		flex-wrap: wrap;
		background: linear-gradient(#000c, transparent);
	}

	.brand {
		display: flex;
		align-items: center;
		gap: 9px;
		font-weight: 700;
		white-space: nowrap;
	}

	.dot {
		width: 9px;
		height: 9px;
		flex-shrink: 0;
		border-radius: 50%;
		background: #eab308;
	}

	.dot.active {
		background: #4ade80;
	}

	.actions {
		display: flex;
		flex-wrap: wrap;
		gap: 8px;
	}

	button {
		border: 1px solid #ffffff35;
		border-radius: 8px;
		padding: 9px 12px;
		color: white;
		background: #171d27e8;
		cursor: pointer;
	}

	button:active {
		background: #303b4b;
	}

	button.armed {
		border-color: #86efac;
		color: #86efac;
	}

	.scan-frame {
		position: absolute;
		top: 46%;
		left: 50%;
		width: min(65vw, 290px);
		aspect-ratio: 1;
		transform: translate(-50%, -50%);
		pointer-events: none;
	}

	.scan-frame span {
		position: absolute;
		width: 27px;
		height: 27px;
		border-color: #86efac;
		border-style: solid;
		border-width: 0;
	}

	.scan-frame span:nth-child(1) {
		top: 0;
		left: 0;
		border-top-width: 4px;
		border-left-width: 4px;
		border-radius: 8px 0 0;
	}

	.scan-frame span:nth-child(2) {
		top: 0;
		right: 0;
		border-top-width: 4px;
		border-right-width: 4px;
		border-radius: 0 8px 0 0;
	}

	.scan-frame span:nth-child(3) {
		bottom: 0;
		left: 0;
		border-bottom-width: 4px;
		border-left-width: 4px;
		border-radius: 0 0 0 8px;
	}

	.scan-frame span:nth-child(4) {
		bottom: 0;
		right: 0;
		border-bottom-width: 4px;
		border-right-width: 4px;
		border-radius: 0 0 8px;
	}

	.scan-hint {
		position: absolute;
		top: calc(46% + min(32.5vw, 145px) + 18px);
		left: 12px;
		right: 12px;
		text-align: center;
		text-shadow: 0 1px 5px black;
		font-size: 14px;
	}

	.cancel-settings-scan {
		background: #53142d;
		border-color: #ef86ac;
		white-space: nowrap;
	}
	.cancel-settings-scan:active {
		background: #41142d;
	}

	.start-button {
		position: absolute;
		top: 46%;
		left: 50%;
		transform: translate(-50%, -50%);
	}

	.error {
		position: absolute;
		z-index: 3;
		top: 100px;
		left: 16px;
		right: 16px;
		padding: 12px;
		border-radius: 8px;
		background: #7f1d1d;
		overflow-wrap: anywhere;
	}

	.error button {
		display: block;
		margin-top: 10px;
	}

	.log-panel {
		position: absolute;
		z-index: 1;
		bottom: 0;
		left: 0;
		right: 0;
		max-height: 34%;
		overflow-y: auto;
		padding: 12px 16px max(16px, env(safe-area-inset-bottom));
		background: #0b1019ee;
		border-top: 1px solid #ffffff20;
		backdrop-filter: blur(12px);
		border-radius: 16px 16px 0 0;
	}

	.log-panel header,
	.settings header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
	}

	.log-panel header {
		position: sticky;
		top: -12px;
		padding: 4px 0 10px;
		background: #0b1019;
	}

	.log-panel header span {
		color: #a1a1aa;
		font-size: 13px;
	}

	.empty {
		color: #a1a1aa;
		font-size: 14px;
	}

	ul {
		list-style: none;
		margin: 0;
		padding: 0;
	}

	li {
		border-top: 1px solid #ffffff12;
	}

	li a,
	.invalid-entry {
		display: flex;
		flex-direction: column;
		gap: 3px;
		padding: 9px 0;
		color: inherit;
		text-decoration: none;
		min-width: 0;
	}

	li a:hover .entry-url {
		color: #86efac;
	}

	.entry-time {
		color: #9ca3af;
		font-size: 11px;
	}

	.entry-url {
		font-size: 13px;
		overflow-wrap: anywhere;
	}

	.backdrop {
		position: absolute;
		z-index: 2;
		inset: 0;
		background: #0009;
	}

	.settings {
		position: absolute;
		z-index: 3;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(92vw, 460px);
		max-height: 88%;
		overflow-y: auto;
		padding: 20px;
		border: 1px solid #ffffff20;
		border-radius: 14px;
		background: #111722;
		box-shadow: 0 16px 60px #0008;
	}

	.settings h2 {
		font-size: 19px;
		margin: 0;
	}

	.settings label {
		display: flex;
		flex-direction: column;
		gap: 6px;
		margin-top: 17px;
		font-size: 13px;
		font-weight: 600;
	}

	.settings input,
	.settings select {
		width: 100%;
		min-width: 0;
		padding: 10px;
		color: white;
		background: #080b10;
		border: 1px solid #374151;
		border-radius: 7px;
		font-weight: 400;
	}

	.settings small,
	.settings-note {
		color: #9ca3af;
		font-size: 12px;
		line-height: 1.5;
		font-weight: 400;
	}

	.settings-note {
		margin-bottom: 0;
	}
	.status {
		font-size: 12px;
		margin-top: 4px;
	}

	.status.pending {
		color: #facc15;
	}

	.status.success {
		color: #4ade80;
	}

	.status.failure {
		color: #f87171;
	}

	.scanner.flash-success::after,
	.scanner.flash-error::after {
		content: '';
		position: absolute;
		inset: 0;
		z-index: 10;
		pointer-events: none;
		animation: flash 350ms ease-out forwards;
	}

	.scanner.flash-success::after {
		background: #22c55e55;
	}

	.scanner.flash-error::after {
		background: #ef444455;
	}

	@keyframes flash {
		from {
			opacity: 1;
		}
		to {
			opacity: 0;
		}
	}

	@media (max-width: 520px) {
		.topbar {
			align-items: flex-start;
		}

		.actions {
			width: 100%;
		}

		.actions button {
			padding: 8px 9px;
			font-size: 12px;
		}

		.log-panel {
			max-height: 32%;
		}
	}
	.settings-qr {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 0.75rem;
		margin-top: 1.5rem;
	}

	.settings-qr img {
		width: 220px;
		height: 220px;
		image-rendering: pixelated;
		background: white;
		padding: 8px;
		border-radius: 8px;
	}

	.settings-qr h3 {
		margin: 0;
	}
</style>
