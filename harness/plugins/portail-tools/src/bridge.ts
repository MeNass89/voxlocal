/**
 * Loopback JSON-RPC 2.0 client for the portal bridge (`harness/bridge/portail_bridge.py`).
 * Holds only the tool-side token: it can read, draft and ask for an approved write, never
 * approve one.
 * @module @voxlocal/portail-tools/bridge
 */

/** Connection settings; the token is resolved from the environment at call time. */
export interface BridgeOptions {
  url: string
  tokenEnv: string
  timeoutMs: number
  env?: NodeJS.ProcessEnv
  fetch?: typeof fetch
}

/** A JSON-RPC error from the bridge, with its HTTP-like status (403, 404, 409, 422…). */
export class BridgeError extends Error {
  override name = 'BridgeError'
  readonly code: number
  readonly data?: unknown
  // No TypeScript parameter properties: dsh loads plugin sources with Node's strip-only mode.
  constructor(code: number, message: string, data?: unknown) {
    super(message)
    this.code = code
    this.data = data
  }
}

const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]'])

export class BridgeClient {
  private seq = 0
  private readonly options: BridgeOptions
  constructor(options: BridgeOptions) {
    this.options = options
    const host = new URL(options.url).hostname
    if (!LOOPBACK.has(host)) throw new Error(`le pont portail doit être en boucle locale, reçu ${host}`)
  }

  async call<T>(method: string, params: Record<string, unknown>, signal?: AbortSignal): Promise<T> {
    const env = this.options.env ?? process.env
    const token = env[this.options.tokenEnv]
    if (token === undefined || token === '') {
      throw new BridgeError(401, `jeton du pont absent : définir ${this.options.tokenEnv}`)
    }
    const id = ++this.seq
    const timeout = AbortSignal.timeout(this.options.timeoutMs)
    const doFetch = this.options.fetch ?? fetch
    let response: Response
    try {
      response = await doFetch(this.options.url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
        body: JSON.stringify({ jsonrpc: '2.0', id, method, params: dropUndefined(params) }),
        signal: signal === undefined ? timeout : AbortSignal.any([signal, timeout]),
      })
    } catch (error) {
      if (signal?.aborted) throw error
      throw new BridgeError(503, `pont portail injoignable (${this.options.url}) : ${(error as Error).message}`)
    }
    const body = await response.json().catch(() => undefined) as
      | { id?: unknown, result?: unknown, error?: { code: number, message: string, data?: unknown } }
      | undefined
    if (body?.error !== undefined) throw new BridgeError(body.error.code, body.error.message, body.error.data)
    if (!response.ok || body === undefined || body.id !== id || !('result' in body)) {
      throw new BridgeError(response.status || 502, `réponse invalide du pont portail (HTTP ${response.status})`)
    }
    return body.result as T
  }
}

function dropUndefined(params: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(params).filter(([, v]) => v !== undefined))
}
