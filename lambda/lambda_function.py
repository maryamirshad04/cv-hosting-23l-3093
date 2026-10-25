"""CV site served by a Lambda function URL.

Settings come from two environment variables:
  BUCKET  name of the private S3 bucket
  PREFIX  key prefix of the site files, for example "site/"

The function URL passes a "payload format 2.0" event. We only use the path.
"""
import base64
import json
import os
import time

import boto3
from botocore.exceptions import ClientError

BUCKET = os.environ["BUCKET"]
PREFIX = os.environ["PREFIX"]

s3 = boto3.client("s3")  # created once, reused while the environment is warm

NOT_FOUND_PAGE = (
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>404 Not Found</title></head>"
    "<body><h1>404 - Page not found</h1><p>This address has no page. "
    "Try <a href=\"/\">the CV</a>.</p></body></html>"
)
ERROR_PAGE = (
    "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>500 Error</title></head>"
    "<body><h1>500 - Something went wrong</h1><p>The CV could not be loaded. Please try again.</p></body></html>"
)

# path -> (S3 file name, content type, is it binary?)
FILES = {
    "/": ("index.html", "text/html", False),
    "/index.html": ("index.html", "text/html", False),
    "/style.css": ("style.css", "text/css", False),
    "/cv.pdf": ("cv.pdf", "application/pdf", True),
}


def _read(name):
    return s3.get_object(Bucket=BUCKET, Key=PREFIX + name)["Body"].read()


def _handle(path, function_name):
    """Return (status, headers, body, is_base64)."""
    entry = FILES.get(path)
    if entry is None:
        return 404, {"Content-Type": "text/html"}, NOT_FOUND_PAGE, False

    name, content_type, binary = entry
    try:
        data = _read(name)
    except ClientError:
        return 500, {"Content-Type": "text/html"}, ERROR_PAGE, False

    headers = {"Content-Type": content_type}
    if binary:
        # API payloads are text, so binary files must be base64 encoded.
        return 200, headers, base64.b64encode(data).decode("ascii"), True

    text = data.decode("utf-8")
    if name == "index.html":
        text = text.replace("{{HOSTED_ON}}", "Lambda " + function_name)
        headers["Cache-Control"] = "max-age=60"
    return 200, headers, text, False


def lambda_handler(event, context):
    start = time.perf_counter()
    path = event.get("rawPath") or event.get("requestContext", {}).get("http", {}).get("path", "/")

    status, headers, body, is_base64 = _handle(path, context.function_name)

    # One JSON line per request.
    print(json.dumps({
        "fn": context.function_name,
        "path": path,
        "status": status,
        "ms": round((time.perf_counter() - start) * 1000, 1),
    }))

    return {
        "statusCode": status,
        "headers": headers,
        "body": body,
        "isBase64Encoded": is_base64,
    }
