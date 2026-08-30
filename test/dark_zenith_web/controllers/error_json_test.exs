defmodule DarkZenithWeb.ErrorJSONTest do
  use DarkZenithWeb.ConnCase, async: true

  test "renders 404 in the API error envelope" do
    assert DarkZenithWeb.ErrorJSON.render("404.json", %{}) ==
             %{"error" => %{"code" => "not_found", "message" => "Not found"}}
  end

  test "renders 500 in the API error envelope" do
    assert DarkZenithWeb.ErrorJSON.render("500.json", %{}) ==
             %{"error" => %{"code" => "internal_error", "message" => "Unexpected server error"}}
  end

  test "renders 413 as payload_too_large" do
    assert %{"error" => %{"code" => "payload_too_large"}} =
             DarkZenithWeb.ErrorJSON.render("413.json", %{})
  end

  test "folds unsupported media type into invalid_request" do
    assert %{"error" => %{"code" => "invalid_request"}} =
             DarkZenithWeb.ErrorJSON.render("415.json", %{})
  end
end
