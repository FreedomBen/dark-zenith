defmodule DarkZenithWeb.CoreComponentsTest do
  use DarkZenithWeb.ConnCase, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias DarkZenithWeb.CoreComponents

  describe "command_block/1" do
    test "renders the command on an Umbra ground in Starlight mono with its own scroll" do
      html =
        render_component(&CoreComponents.command_block/1, %{
          id: "install-cmd",
          command: "dnf install htop"
        })

      assert html =~ "bg-umbra"
      assert html =~ "text-starlight"
      assert html =~ "font-mono"
      assert html =~ "overflow-x-auto"
      assert html =~ ~s(id="install-cmd")

      # <pre> preserves every character: the command must sit flush inside
      # <code> with no incidental template whitespace to display or copy
      assert html =~ "<code>dnf install htop</code>"
    end

    test "has a copy button dispatching dz:copy at the block, with the check confirmation" do
      html =
        render_component(&CoreComponents.command_block/1, %{id: "copyable", command: "echo hi"})

      assert html =~ ~s(aria-label="Copy to clipboard")
      assert html =~ "dz:copy"
      assert html =~ "#copyable"
      assert html =~ "hero-clipboard-micro"
      assert html =~ "hero-check-micro"
      # icon swap is driven by the dz-copied class the app.js listener toggles
      assert html =~ "dz-copied"
    end

    test "renders an optional eyebrow label" do
      html =
        render_component(&CoreComponents.command_block/1, %{
          id: "labeled",
          eyebrow: "DNF 5",
          command: "dnf5 install htop"
        })

      assert html =~ "DNF 5"
      assert html =~ "uppercase"
    end

    test "omits the eyebrow markup when none is given" do
      html =
        render_component(&CoreComponents.command_block/1, %{id: "plain", command: "true"})

      refute html =~ "uppercase"
    end
  end

  describe "badge/1" do
    test "maps every semantic variant to its spec classes and default label" do
      expectations = [
        {:public, "badge-outline badge-secondary", "Public"},
        {:private, "badge-soft badge-neutral", "Private"},
        {:metadata_signed, "badge-soft badge-accent", "Metadata signed"},
        {:auto_sign, "badge-outline badge-primary", "Auto-sign"},
        {:signing, "badge-soft badge-warning", "signing"},
        {:failed, "badge-soft badge-error", "failed"},
        {:queued, "badge-soft badge-neutral", "queued"},
        {:sent, "badge-soft badge-success", "sent"},
        {:suppressed, "badge-soft badge-warning", "suppressed"},
        {:processing, "badge-soft badge-warning", "processing"},
        {:preview_ready, "badge-soft badge-accent", "preview ready"}
      ]

      for {variant, classes, label} <- expectations do
        html = render_component(&CoreComponents.badge/1, %{variant: variant})
        assert html =~ classes, "#{variant} should carry #{classes}"
        assert html =~ label, "#{variant} should default to the label #{label}"
      end
    end

    test "the private badge carries a lock icon" do
      html = render_component(&CoreComponents.badge/1, %{variant: :private})
      assert html =~ "hero-lock-closed-micro"
    end

    test "an inner block overrides the default label and extra classes pass through" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.badge variant={:public} class="badge-sm">
          visible to everyone
        </CoreComponents.badge>
        """)

      assert html =~ "visible to everyone"
      refute html =~ ">Public<"
      assert html =~ "badge-sm"
    end
  end

  describe "table/1" do
    defp sample_rows do
      [
        %{name: "htop", evr: "3.4.1-1.fc44", size: 250},
        %{name: "zsh", evr: "5.9-5.fc44", size: 3100}
      ]
    end

    test "renders the dense catalog conventions" do
      assigns = %{rows: sample_rows()}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="pkgs" rows={@rows}>
          <:col :let={row} label="Name" mono>{row.name}</:col>
          <:col :let={row} label="Size" align={:right}>{row.size}</:col>
        </CoreComponents.table>
        """)

      assert html =~ "overflow-x-auto"
      assert html =~ "table-sm"
      refute html =~ "table-zebra"
      # uppercase eyebrow-style headers
      assert html =~ "uppercase"
      assert html =~ "tracking-wider"
      # hairline dividers and row hover
      assert html =~ "border-base-content/10"
      assert html =~ "hover:bg-base-200"
      # mono column, right-aligned numeric column
      assert html =~ "font-mono"
      assert html =~ "text-right"
    end

    test "a sortable header is a real button cycling asc to desc with a chevron" do
      assigns = %{rows: sample_rows(), sort: "name"}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="pkgs" rows={@rows} sort={@sort} sort_event="sort">
          <:col :let={row} label="Name" sort="name">{row.name}</:col>
          <:col :let={row} label="Size">{row.size}</:col>
        </CoreComponents.table>
        """)

      assert html =~ ~s(phx-click="sort")
      # active ascending column: clicking flips to descending
      assert html =~ ~s(phx-value-sort="-name")
      assert html =~ "hero-chevron-up-micro"
      assert html =~ ~s(aria-sort="ascending")
      # the unsortable column renders no button
      assert length(Regex.scan(~r/<button/, html)) == 1
    end

    test "a descending sort shows the down chevron and flips back to ascending" do
      assigns = %{rows: sample_rows(), sort: "-name"}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="pkgs" rows={@rows} sort={@sort} sort_event="sort">
          <:col :let={row} label="Name" sort="name">{row.name}</:col>
        </CoreComponents.table>
        """)

      assert html =~ ~s(phx-value-sort="name")
      assert html =~ "hero-chevron-down-micro"
      assert html =~ ~s(aria-sort="descending")
    end

    test "an inactive sortable column shows no chevron and sorts ascending first" do
      assigns = %{rows: sample_rows(), sort: "name"}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="pkgs" rows={@rows} sort={@sort} sort_event="sort">
          <:col :let={row} label="Arch" sort="arch">{row.name}</:col>
        </CoreComponents.table>
        """)

      assert html =~ ~s(phx-value-sort="arch")
      refute html =~ "hero-chevron"
      refute html =~ "aria-sort"
    end

    test "sortable columns without a sort_event fall back to plain headers" do
      assigns = %{rows: sample_rows()}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="pkgs" rows={@rows}>
          <:col :let={row} label="Name" sort="name">{row.name}</:col>
        </CoreComponents.table>
        """)

      refute html =~ "<button"
    end
  end

  describe "modal/1" do
    test "renders nothing while hidden" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.modal id="confirm" show={false} on_cancel="cancel">content</CoreComponents.modal>
        """)

      refute html =~ "content"
      refute html =~ "modal-open"
    end

    test "renders an open dialog with backdrop and escape cancel when shown" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.modal id="confirm" show={true} on_cancel="cancel">
          the consequence
        </CoreComponents.modal>
        """)

      assert html =~ "modal-open"
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ "the consequence"
      assert html =~ "modal-backdrop"
      assert html =~ ~s(phx-key="escape")
      assert html =~ ~s(phx-window-keydown="cancel")
    end
  end

  describe "confirm_modal/1" do
    test "renders nothing without a pending confirmation" do
      html = render_component(&CoreComponents.confirm_modal/1, %{pending: nil})

      refute html =~ "modal-open"
    end

    test "renders the pending consequence with cancel and run actions" do
      html =
        render_component(&CoreComponents.confirm_modal/1, %{
          pending: %{
            event: "remove_thing",
            params: %{},
            title: "Remove thing",
            message: "It stays removed.",
            confirm_label: "Remove it"
          }
        })

      assert html =~ "modal-open"
      assert html =~ "Remove thing"
      assert html =~ "It stays removed."
      assert html =~ "Remove it"
      assert html =~ ~s(phx-click="cancel_confirm")
      assert html =~ ~s(phx-click="run_confirm")
      assert html =~ "btn-error"
    end
  end

  describe "header/1" do
    test "titles render in the display face at page-title scale" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.header>Repositories</CoreComponents.header>
        """)

      assert html =~ "font-display"
      assert html =~ "text-2xl"
    end
  end

  describe "button/1 variants" do
    test "supports the spec hierarchy: outline, ghost, and error variants" do
      for {variant, class} <- [
            {"primary", "btn-primary"},
            {"outline", "btn-outline"},
            {"ghost", "btn-ghost"},
            {"error", "btn-error"}
          ] do
        assigns = %{variant: variant}

        html =
          rendered_to_string(~H"""
          <CoreComponents.button variant={@variant}>Act</CoreComponents.button>
          """)

        assert html =~ class
      end
    end

    test "keeps the soft primary default" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button>Act</CoreComponents.button>
        """)

      assert html =~ "btn-primary btn-soft"
    end
  end

  describe "input/1 help text" do
    test "renders muted help text below the field" do
      html =
        render_component(&CoreComponents.input/1, %{
          name: "slug",
          value: "",
          label: "Slug",
          help: "Immutable after creation."
        })

      assert html =~ "Immutable after creation."
      assert html =~ "text-xs"
      assert html =~ "text-base-content/70"
    end
  end

  describe "flash/1" do
    test "sits below the h-14 header and uses the soft alert style" do
      html =
        render_component(&CoreComponents.flash/1, %{
          kind: :info,
          flash: %{"info" => "Saved."}
        })

      assert html =~ "mt-14"
      assert html =~ "alert-soft"
      assert html =~ "Saved."
    end
  end
end
