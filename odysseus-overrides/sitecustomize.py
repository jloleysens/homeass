"""Compatibility fixes for the pinned Odysseus release."""

from src import chatgpt_subscription


_original_chatgpt_headers = chatgpt_subscription.chatgpt_headers


def _chatgpt_headers_with_account(access_token):
    headers = _original_chatgpt_headers(access_token)
    if not access_token:
        return headers

    try:
        claims = chatgpt_subscription._decode_jwt_payload(access_token)
        auth = claims.get("https://api.openai.com/auth") or {}
        account_id = auth.get("chatgpt_account_id")
    except Exception:
        account_id = None

    if account_id:
        headers["ChatGPT-Account-Id"] = account_id
    return headers


chatgpt_subscription.chatgpt_headers = _chatgpt_headers_with_account
