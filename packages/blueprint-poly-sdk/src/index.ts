export interface Client {
  readonly baseUrl: string
  url(path: string): string
}

/** A client for the service at `baseUrl`; `url` joins a request path onto it. */
export function createClient(baseUrl: string): Client {
  const base = baseUrl.replace(/\/+$/, '')
  return { baseUrl: base, url: (path) => `${base}/${path.replace(/^\/+/, '')}` }
}
