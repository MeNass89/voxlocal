/**
 * Minimal client for the VoxLocal dictation API: the Mac loopback API
 * (`LocalAPI.swift`, 127.0.0.1:47367) or the Python agent API in `--mock`
 * mode (127.0.0.1:47366). Both serve the same envelope and record shape.
 * @module @voxlocal/dsh-voxlocal-tools/client
 */

/** One dictation as served by VoxLocal. The API never includes an audio path. */
export interface Dictation {
  id: string
  timestamp: string
  deviceName: string
  modeId: string
  rawTranscription: string
  finalTranscription: string
  processingStatus: string
  duration: number
  patientContext: string | null
}

export interface ClientOptions {
  apiUrl: string
  /** Read at call time so a rotated token never needs a restart. */
  token: () => string | undefined
  timeoutMs: number
}

/** Error with the API's stable `error.code`, for callers and tests. */
export class VoxLocalAPIError extends Error {
  readonly code: string
  readonly status: number
  // No TypeScript parameter properties: dsh loads plugin sources with Node's strip-only mode.
  constructor(code: string, message: string, status: number) {
    super(message)
    this.name = 'VoxLocalAPIError'
    this.code = code
    this.status = status
  }
}

/**
 * Plain HTTP is accepted only for loopback: the Bearer token and clinical text
 * must never cross the network in clear.
 */
export function validateApiUrl(value: string): string {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    throw new Error(`VOXLOCAL_API_URL invalide : ${value}`)
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new Error('VOXLOCAL_API_URL : ni identifiants, ni query, ni fragment.')
  }
  const loopback = ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
  if (url.protocol === 'http:' && !loopback) {
    throw new Error('VOXLOCAL_API_URL : HTTP est réservé à 127.0.0.1 ; utilisez HTTPS pour un autre hôte.')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error('VOXLOCAL_API_URL doit être HTTP(S).')
  }
  return url.toString().replace(/\/+$/, '')
}

export class VoxLocalClient {
  private readonly base: string
  private readonly options: ClientOptions

  constructor(options: ClientOptions) {
    this.options = options
    this.base = validateApiUrl(options.apiUrl)
  }

  /** Records after `since` (oldest first); no long-poll from a tool call. */
  async list(since: string | undefined, signal: AbortSignal): Promise<Dictation[]> {
    const query = since ? `?since=${encodeURIComponent(since)}` : ''
    const data = await this.request<{ dictations: Dictation[] }>('GET', `/v1/dictations${query}`, signal)
    return data.dictations
  }

  async get(id: string, signal: AbortSignal): Promise<Dictation> {
    return this.request<Dictation>('GET', `/v1/dictations/${encodeURIComponent(id)}`, signal)
  }

  async retranscribe(id: string, signal: AbortSignal): Promise<{ id: string, status: string }> {
    return this.request('POST', `/v1/dictations/${encodeURIComponent(id)}/retranscribe`, signal, {})
  }

  private async request<T>(method: string, path: string, signal: AbortSignal, body?: unknown): Promise<T> {
    const token = this.options.token()
    if (!token) throw new VoxLocalAPIError('missing_token', 'Token VoxLocal absent : définissez VOXLOCAL_API_TOKEN (Réglages › iPhone › Harness local › Copier).', 0)
    const headers: Record<string, string> = { Authorization: `Bearer ${token}`, Accept: 'application/json' }
    if (body !== undefined) headers['Content-Type'] = 'application/json'
    let response: Response
    try {
      response = await fetch(this.base + path, {
        method,
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        redirect: 'error',
        signal: AbortSignal.any([signal, AbortSignal.timeout(this.options.timeoutMs)]),
      })
    } catch (error) {
      if (signal.aborted) throw error
      throw new VoxLocalAPIError('connection_error', 'VoxLocal injoignable : vérifiez que « Exposer les dictées au harness local » est activé.', 0)
    }
    let envelope: { ok?: boolean, data?: unknown, error?: { code?: string, message?: string } }
    try {
      envelope = await response.json() as typeof envelope
    } catch {
      throw new VoxLocalAPIError('invalid_response', `Réponse VoxLocal illisible (HTTP ${response.status}).`, response.status)
    }
    if (!response.ok || envelope.ok !== true) {
      throw new VoxLocalAPIError(envelope.error?.code ?? 'http_error', envelope.error?.message ?? `Erreur VoxLocal HTTP ${response.status}.`, response.status)
    }
    return envelope.data as T
  }
}
