"""Python SDK of blueprint-poly-pkg."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Client:
    base_url: str

    def url(self, path: str) -> str:
        return f"{self.base_url}/{path.lstrip('/')}"


def create_client(base_url: str) -> Client:
    """A client for the service at base_url; url joins a request path onto it."""
    return Client(base_url.rstrip("/"))
