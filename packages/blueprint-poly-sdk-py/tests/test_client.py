from blueprint_poly_sdk_py import create_client


def test_url_joins_the_path_onto_the_base_without_doubling_the_slash():
    client = create_client("https://example.com/")
    assert client.base_url == "https://example.com"
    assert client.url("/healthz") == "https://example.com/healthz"
