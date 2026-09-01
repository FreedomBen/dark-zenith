defmodule DarkZenithWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: DarkZenithWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50 mt-14"
      {@rest}
    >
      <div class={[
        "alert alert-soft w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        "border border-base-content/10 shadow-lg",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary outline ghost error)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    # docs/DESIGN_UI.md — Buttons: one primary per view, outline secondary,
    # ghost tertiary, error destructive.
    variants = %{
      "primary" => "btn-primary",
      "outline" => "btn-outline",
      "ghost" => "btn-ghost",
      "error" => "btn-error",
      nil => "btn-primary btn-soft"
    }

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :help, :string, default: nil, doc: "muted help text rendered below the field"
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <p :if={@help} class="mt-1 text-xs text-base-content/70">{@help}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <p :if={@help} class="mt-1 text-xs text-base-content/70">{@help}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <p :if={@help} class="mt-1 text-xs text-base-content/70">{@help}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <p :if={@help} class="mt-1 text-xs text-base-content/70">{@help}</p>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a page title block (docs/DESIGN_UI.md — Typography): a Spectral
  title with an optional one-line muted description. Data titles (package
  names, NEVRA) pass a `font-mono` span in the inner block, which overrides
  the display face.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="font-display text-2xl font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table in the dense catalog style (docs/DESIGN_UI.md — Tables):
  uppercase eyebrow headers, hairline row dividers, row hover, mono and
  right-aligned columns, and sortable headers as real buttons. The table
  scrolls inside its own container.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>

  Sortable columns take the table's current `sort` (e.g. `"name"` ascending,
  `"-name"` descending) and a `sort_event`; a header click sends the event
  with the next sort under `phx-value-sort`:

      <.table id="pkgs" rows={@packages} sort={@sort} sort_event="sort">
        <:col :let={p} label="Name" sort="name" mono>{p.name}</:col>
        <:col :let={p} label="Size" align={:right}>{p.size}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"
  attr :sort, :string, default: nil, doc: "the current sort, a key optionally prefixed with -"
  attr :sort_event, :string, default: nil, doc: "the event a sortable header click pushes"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
    attr :sort, :string, doc: "the sort key this column's header toggles"
    attr :mono, :boolean, doc: "render the column in the mono face"
    attr :align, :atom, doc: "column alignment; :right for numeric columns"
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-x-auto">
      <table class="table table-sm">
        <thead>
          <tr>
            <th
              :for={col <- @col}
              class={[
                "text-xs font-medium uppercase tracking-wider text-base-content/70",
                col[:align] == :right && "text-right"
              ]}
              aria-sort={@sort_event && col[:sort] && aria_sort(@sort, col[:sort])}
            >
              <button
                :if={@sort_event && col[:sort]}
                type="button"
                phx-click={@sort_event}
                phx-value-sort={next_sort(@sort, col[:sort])}
                class="inline-flex cursor-pointer items-center gap-1 uppercase tracking-wider hover:text-base-content"
              >
                {col[:label]}
                <.icon
                  :if={@sort == col[:sort]}
                  name="hero-chevron-up-micro"
                  class="size-3"
                />
                <.icon
                  :if={@sort == "-" <> col[:sort]}
                  name="hero-chevron-down-micro"
                  class="size-3"
                />
              </button>
              <span :if={!(@sort_event && col[:sort])}>{col[:label]}</span>
            </th>
            <th :if={@action != []}>
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
          <tr
            :for={row <- @rows}
            id={@row_id && @row_id.(row)}
            class="border-b border-base-content/10 hover:bg-base-200"
          >
            <td
              :for={col <- @col}
              phx-click={@row_click && @row_click.(row)}
              class={[
                @row_click && "hover:cursor-pointer",
                col[:mono] && "font-mono whitespace-nowrap",
                col[:align] == :right && "text-right"
              ]}
            >
              {render_slot(col, @row_item.(row))}
            </td>
            <td :if={@action != []} class="w-0 font-semibold">
              <div class="flex gap-4">
                <%= for action <- @action do %>
                  {render_slot(action, @row_item.(row))}
                <% end %>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  # Clicking an active ascending header flips to descending; anything else
  # (inactive, or active descending) sorts ascending.
  defp next_sort(current, key) when current == key, do: "-" <> key
  defp next_sort(_current, key), do: key

  defp aria_sort(current, key) when current == key, do: "ascending"

  defp aria_sort(current, key) do
    if current == "-" <> key, do: "descending"
  end

  @doc """
  Renders a copy-paste command block (docs/DESIGN_UI.md — Components): Umbra
  ground in both themes, Starlight mono text, an optional eyebrow label, and a
  copy button that confirms with a checkmark. Long commands scroll
  horizontally instead of wrapping.

  The command is an attribute, not a slot, because `<pre>` preserves every
  character: slot content would render (and copy) the template's indentation.

  The copy button dispatches `dz:copy` at the block; the app.js listener
  copies the `<code>` text and toggles the `dz-copied` class for the icon
  swap.

  ## Examples

      <.command_block id="install-cmd" command="dnf install htop" />
      <.command_block id="dnf5-add" eyebrow="DNF 5" command={@addrepo_command} />
  """
  attr :id, :string, required: true
  attr :command, :string, required: true, doc: "the exact text to display and copy"
  attr :eyebrow, :string, default: nil, doc: "small uppercase label above the command"
  attr :class, :any, default: nil

  def command_block(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "dz-command-block relative rounded-box border border-base-content/10 bg-umbra text-starlight",
        @class
      ]}
    >
      <div
        :if={@eyebrow}
        class="px-4 pt-3 font-mono text-[11px] uppercase tracking-wider text-starlight/60"
      >
        {@eyebrow}
      </div>
      <pre class={[
        "overflow-x-auto px-4 pr-12 font-mono text-sm",
        (@eyebrow && "pt-1 pb-3") || "py-3"
      ]}><code>{@command}</code></pre>
      <button
        type="button"
        class="absolute top-1.5 right-1.5 cursor-pointer rounded-field p-1.5 text-starlight/60 hover:bg-starlight/10 hover:text-starlight"
        phx-click={JS.dispatch("dz:copy", to: "##{@id}")}
        aria-label={gettext("Copy to clipboard")}
      >
        <.icon name="hero-clipboard-micro" class="size-4 [.dz-copied_&]:hidden" />
        <%!-- confirmation color is fixed: the ground never follows the theme --%>
        <.icon
          name="hero-check-micro"
          class="hidden size-4 text-[#58b77e] [.dz-copied_&]:inline-block"
        />
      </button>
    </div>
    """
  end

  @badge_variants %{
    public: {"badge-outline badge-secondary", "Public", nil},
    private: {"badge-soft badge-neutral", "Private", "hero-lock-closed-micro"},
    metadata_signed: {"badge-soft badge-accent", "Metadata signed", nil},
    auto_sign: {"badge-outline badge-primary", "Auto-sign", nil},
    signing: {"badge-soft badge-warning", "signing", nil},
    failed: {"badge-soft badge-error", "failed", nil},
    queued: {"badge-soft badge-neutral", "queued", nil},
    sent: {"badge-soft badge-success", "sent", nil},
    suppressed: {"badge-soft badge-warning", "suppressed", nil},
    processing: {"badge-soft badge-warning", "processing", nil},
    preview_ready: {"badge-soft badge-accent", "preview ready", nil}
  }

  @doc """
  Renders a domain-state badge (docs/DESIGN_UI.md — Badges): each variant maps
  a state to its semantic token. The inner block overrides the default label.

  ## Examples

      <.badge variant={:private} />
      <.badge variant={:sent} class="badge-sm" />
  """
  attr :variant, :atom, required: true, values: Map.keys(@badge_variants)
  attr :class, :any, default: nil
  slot :inner_block

  def badge(assigns) do
    {classes, label, icon} = Map.fetch!(@badge_variants, assigns.variant)
    assigns = assign(assigns, classes: classes, label: label, icon: icon)

    ~H"""
    <span class={["badge", @classes, @class]}>
      <.icon :if={@icon} name={@icon} class="size-3" />
      <%= if @inner_block == [] do %>
        {@label}
      <% else %>
        {render_slot(@inner_block)}
      <% end %>
    </span>
    """
  end

  @doc """
  Renders a modal dialog for destructive confirmations (docs/DESIGN_UI.md —
  Dialogs). Visibility is server-driven through `show`; the backdrop and the
  Escape key both push `on_cancel`.

  ## Examples

      <.modal id="delete_modal" show={@show_delete} on_cancel="cancel_delete">
        <h3>Delete repository</h3>
        ...
      </.modal>
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, :any, default: nil, doc: "event name or JS command pushed on dismiss"
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      :if={@show}
      id={@id}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      phx-window-keydown={@on_cancel}
      phx-key="escape"
    >
      <div class="modal-box border border-base-content/10">
        {render_slot(@inner_block)}
      </div>
      <div class="modal-backdrop" phx-click={@on_cancel} aria-hidden="true"></div>
    </div>
    """
  end

  @doc """
  Renders the shared confirmation dialog for destructive actions
  (docs/DESIGN_UI.md — Dialogs). The LiveView assigns a pending map with
  `:title`, `:message`, and `:confirm_label` to open it, and handles
  `cancel_confirm` (dismiss) and `run_confirm` (execute); `nil` hides it.

  ## Examples

      <.confirm_modal pending={@pending_confirm} />
  """
  attr :pending, :map, default: nil

  def confirm_modal(assigns) do
    ~H"""
    <.modal id="confirm_modal" show={@pending != nil} on_cancel="cancel_confirm">
      <h3 class="text-lg font-semibold">{@pending.title}</h3>
      <p class="py-3 text-sm">{@pending.message}</p>
      <div class="modal-action">
        <button type="button" class="btn btn-ghost" phx-click="cancel_confirm">
          {gettext("Cancel")}
        </button>
        <button type="button" id="confirm_action" class="btn btn-error" phx-click="run_confirm">
          {@pending.confirm_label}
        </button>
      </div>
    </.modal>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(DarkZenithWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(DarkZenithWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
