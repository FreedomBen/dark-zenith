defmodule DarkZenith.B2.SigV4Test do
  use ExUnit.Case, async: true

  alias DarkZenith.B2.SigV4

  # The documented AWS Signature Version 4 example credentials and time
  # (Amazon S3 API Reference, "Authenticating Requests" examples).
  @access_key "AKIAIOSFODNN7EXAMPLE"
  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @region "us-east-1"
  @now ~U[2013-05-24 00:00:00Z]

  test "reproduces the documented presigned GET URL signature" do
    url =
      SigV4.presign_url("GET", "https://examplebucket.s3.amazonaws.com/test.txt",
        access_key_id: @access_key,
        secret_access_key: @secret,
        region: @region,
        ttl: 86_400,
        now: @now
      )

    assert url =~ "X-Amz-Algorithm=AWS4-HMAC-SHA256"

    assert url =~
             "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request"

    assert url =~ "X-Amz-Date=20130524T000000Z"
    assert url =~ "X-Amz-Expires=86400"
    assert url =~ "X-Amz-SignedHeaders=host"

    assert url =~
             "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "reproduces the documented header-authorized GET signature" do
    headers =
      SigV4.sign_headers(
        "GET",
        "https://examplebucket.s3.amazonaws.com/test.txt",
        [{"range", "bytes=0-9"}],
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        access_key_id: @access_key,
        secret_access_key: @secret,
        region: @region,
        now: @now
      )

    authorization = :proplists.get_value("authorization", headers)

    assert authorization ==
             "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request," <>
               "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date," <>
               "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"

    assert :proplists.get_value("x-amz-date", headers) == "20130524T000000Z"
  end

  test "signs extra headers and query parameters into presigned URLs" do
    url =
      SigV4.presign_url("PUT", "https://s3.example.com/bucket/staging/uploads/key.rpm",
        access_key_id: "k",
        secret_access_key: "s",
        region: "eu-1",
        ttl: 3600,
        now: @now,
        signed_headers: [
          {"content-length", "12345"},
          {"content-type", "application/x-rpm"}
        ]
      )

    assert url =~ "X-Amz-SignedHeaders=content-length%3Bcontent-type%3Bhost"

    versioned =
      SigV4.presign_url("GET", "https://s3.example.com/bucket/key.rpm",
        access_key_id: "k",
        secret_access_key: "s",
        region: "eu-1",
        ttl: 60,
        now: @now,
        query: [{"versionId", "4_zabc123"}]
      )

    assert versioned =~ "versionId=4_zabc123"

    # The method participates in the signature: HEAD and GET differ.
    head_signed =
      SigV4.presign_url("HEAD", "https://s3.example.com/bucket/key.rpm",
        access_key_id: "k",
        secret_access_key: "s",
        region: "eu-1",
        ttl: 60,
        now: @now,
        query: [{"versionId", "4_zabc123"}]
      )

    assert signature_of(versioned) != signature_of(head_signed)
  end

  test "encodes path segments without touching separators" do
    url =
      SigV4.presign_url("GET", "https://s3.example.com/bucket/a key+plus/b~tilde",
        access_key_id: "k",
        secret_access_key: "s",
        region: "r",
        ttl: 60,
        now: @now
      )

    assert url =~ "/bucket/a%20key%2Bplus/b~tilde?"
  end

  defp signature_of(url) do
    %{"X-Amz-Signature" => signature} = URI.decode_query(URI.parse(url).query)
    signature
  end
end
