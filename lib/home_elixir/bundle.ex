defmodule HomeElixir.Bundle do
  @moduledoc """
  Pack and unpack a set of flow sources for import/export, in three formats:

    * `:json` — a `{flowName => source}` object. Pure Elixir (Jason); always available.
    * `:tar`  — a `.tar` of the `.ex` files, via the system `tar`.
    * `:zip`  — a `.zip` of the `.ex` files, via OTP's `:zip` module (present in the
      release image's full OTP; may be absent in a stripped build).

  `produce/2` turns `[{name, source}]` into bytes; `consume/2` turns bytes back into
  `[{label, source}]`. A flow's identity is always taken from its source's `defmodule`
  downstream (the name here is a label/fallback only).
  """

  # The release image ships the standard OTP :zip; some stripped builds (like the
  # dev OTP) carry a non-standard :zip without these functions, so the calls are
  # only ever made when available?/1 confirms they exist.
  @compile {:no_warn_undefined, :zip}

  @doc "The supported formats."
  def formats, do: [:zip, :tar, :json]

  @doc "Whether a format is usable in this build."
  def available?(:json), do: true
  def available?(:tar), do: System.find_executable("tar") != nil

  # :zip is only "available" when the standard OTP functions are present. Some
  # builds ship a non-standard :zip (missing open/read_entry_zip), which we don't
  # use — the release image's standard OTP :zip is the target.
  def available?(:zip) do
    Code.ensure_loaded?(:zip) and
      function_exported?(:zip, :create, 2) and
      function_exported?(:zip, :open, 1) and
      function_exported?(:zip, :list_entry_zip, 1) and
      function_exported?(:zip, :read_entry_zip, 2)
  end

  @doc "Parse a format string (`zip`/`tar`/`json`); `:none` if unknown."
  def parse_format("zip"), do: :zip
  def parse_format("tar"), do: :tar
  def parse_format("json"), do: :json
  def parse_format(_), do: :none

  @doc "The download filename for a format."
  def filename(:zip), do: "home-elixir-flows.zip"
  def filename(:tar), do: "home-elixir-flows.tar"
  def filename(:json), do: "home-elixir-flows.json"

  @doc "The content type for a format."
  def content_type(:zip), do: "application/zip"
  def content_type(:tar), do: "application/x-tar"
  def content_type(:json), do: "application/json"

  @doc """
  Produce the flow bundle as bytes. `flows` is `[{name, source}]`.
  Returns `{:ok, {bytes, filename, content_type}}` or `{:error, reason}`.
  """
  def produce(flows, format)

  def produce(flows, :json) do
    data = Map.new(flows)
    {:ok, {Jason.encode!(data, pretty: true), filename(:json), content_type(:json)}}
  end

  def produce(flows, :tar) do
    with :ok <- require_tar() do
      base = tmp("he_bundle")
      workdir = Path.join(base, "work")
      File.mkdir_p!(workdir)

      for {name, src} <- flows do
        path = Path.join(workdir, name <> ".ex")
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, src)
      end

      tarring = Path.join(base, "out.tar")

      try do
        _ = System.cmd("tar", ["cf", tarring, "-C", workdir, "."])
        {:ok, {File.read!(tarring), filename(:tar), content_type(:tar)}}
      rescue
        e -> {:error, "tar failed: " <> Exception.message(e)}
      after
        File.rm_rf!(base)
      end
    end
  end

  def produce(flows, :zip) do
    with :ok <- require_zip() do
      base = tmp("he_bundle")
      File.mkdir_p!(base)
      zip = Path.join(base, "out.zip")
      entries = Enum.map(flows, fn {name, src} -> {String.to_charlist(name <> ".ex"), src} end)

      try do
        {:ok, _} = :zip.create(String.to_charlist(zip), entries)
        {:ok, {File.read!(zip), filename(:zip), content_type(:zip)}}
      rescue
        e -> {:error, "zip failed: " <> Exception.message(e)}
      after
        File.rm_rf!(base)
      end
    end
  end

  @doc """
  Parse a bundle back into `[{label, source}]`. Returns `{:ok, pairs}` or
  `{:error, reason}`.
  """
  def consume(bytes, format)

  def consume(bytes, :json) do
    case Jason.decode(bytes) do
      {:ok, %{} = m} -> {:ok, Map.to_list(m)}
      _ -> {:error, "expected a JSON object of {flowName: source}"}
    end
  end

  def consume(bytes, :tar) do
    with :ok <- require_tar() do
      base = tmp("he_bundle")
      workdir = Path.join(base, "work")
      File.mkdir_p!(workdir)
      tarring = Path.join(base, "in.tar")
      File.write!(tarring, bytes)

      try do
        _ = System.cmd("tar", ["xf", tarring, "-C", workdir])
        {:ok, ex_files(workdir)}
      rescue
        e -> {:error, "tar failed: " <> Exception.message(e)}
      after
        File.rm_rf!(base)
      end
    end
  end

  def consume(bytes, :zip) do
    with :ok <- require_zip() do
      base = tmp("he_bundle")
      File.mkdir_p!(base)
      zip = Path.join(base, "in.zip")
      File.write!(zip, bytes)

      try do
        case :zip.open(String.to_charlist(zip)) do
          {:ok, z} ->
            pairs =
              for {name, _info} <- :zip.list_entry_zip(z),
                  sname = to_string(name),
                  safe_name?(sname),
                  String.ends_with?(sname, ".ex"),
                  {:ok, data} <- [:zip.read_entry_zip(z, name)] do
                {strip_ex(sname), data}
              end

            :zip.close(z)
            {:ok, pairs}

          {:error, reason} ->
            {:error, "bad zip: #{inspect(reason)}"}
        end
      rescue
        e -> {:error, "zip failed: " <> Exception.message(e)}
      after
        File.rm_rf!(base)
      end
    end
  end

  # ---- internals ----

  defp require_tar, do: if(available?(:tar), do: :ok, else: {:error, "tar not available"})
  defp require_zip, do: if(available?(:zip), do: :ok, else: {:error, "zip not available in this build"})

  # Read the *.ex files under a dir as {flow_name, contents} (the .ex suffix is
  # stripped so labels match the JSON format).
  defp ex_files(workdir) do
    workdir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      {strip_ex(Path.relative_to(path, workdir)), File.read!(path)}
    end)
  end

  defp tmp(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
  end

  defp strip_ex(name) do
    if String.ends_with?(name, ".ex"), do: String.trim_trailing(name, ".ex"), else: name
  end

  # Reject zip entry names that escape the archive (zip-slip) or are absolute.
  defp safe_name?(name) do
    not String.starts_with?(name, "/") and
      not Enum.any?(String.split(name, "/"), &(&1 in ["..", ""]))
  end
end
