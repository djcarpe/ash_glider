defmodule AshGlider.Type do
  @moduledoc """
  Moving Ash attribute values in and out of glider properties.

  glider's value domain is deliberately small — null, boolean, integer, float,
  text, and lists of those. Ash's is not. So each attribute is encoded on the
  way in and decoded on the way out, using the **resource's own type** as the
  guide rather than a marker smuggled into the stored value.

  That choice is what keeps the stored graph legible. A `:utc_datetime` lands
  as an ISO 8601 string, not an opaque blob, so the same data is readable from
  `glider browser`, from the WebAssembly build, or by any other client. The
  cost is that changing an attribute's type is a migration, exactly as it would
  be in a SQL data layer.
  """

  @doc """
  Encode a value already dumped by `Ash.Type.dump_to_native/3` into something
  glider can store.
  """
  @spec encode(term()) :: term()
  def encode(nil), do: nil
  def encode(value) when is_boolean(value), do: value
  def encode(value) when is_integer(value), do: value
  def encode(value) when is_float(value), do: value

  def encode(value) when is_binary(value) do
    # Some Ash types dump to raw bytes rather than text — `:uuid` is the one
    # everybody hits, since it dumps to 16 binary octets. glider stores text,
    # and the NIF boundary requires valid UTF-8, so those have to be made
    # printable.
    cond do
      String.valid?(value) ->
        value

      byte_size(value) == 16 ->
        # Prefer the canonical UUID spelling over base64: it round-trips
        # through cast_stored/3 unchanged, and it stays readable in
        # `glider browser` instead of becoming an opaque blob.
        case Ecto.UUID.load(value) do
          {:ok, uuid} -> uuid
          :error -> Base.encode64(value)
        end

      true ->
        Base.encode64(value)
    end
  end

  def encode(value) when is_atom(value), do: Atom.to_string(value)

  def encode(%Decimal{} = value), do: Decimal.to_string(value)
  def encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encode(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def encode(%Date{} = value), do: Date.to_iso8601(value)
  def encode(%Time{} = value), do: Time.to_iso8601(value)

  def encode(value) when is_list(value) do
    # glider lists hold scalars only, so a list of maps is JSON rather than a
    # list of encoded elements.
    if Enum.all?(value, &scalar?/1) do
      Enum.map(value, &encode/1)
    else
      json(value)
    end
  end

  def encode(value) when is_map(value), do: json(value)
  def encode(value), do: json(value)

  defp scalar?(v),
    do: is_nil(v) or is_boolean(v) or is_integer(v) or is_float(v) or is_binary(v) or is_atom(v)

  defp json(value), do: Jason.encode!(value)

  @doc """
  Decode a stored glider property back into something
  `Ash.Type.cast_stored/3` will accept for `type`.
  """
  @spec decode(term(), Ash.Type.t(), Keyword.t()) :: term()
  def decode(nil, _type, _constraints), do: nil

  def decode(value, type, constraints) do
    case Ash.Type.get_type(type) do
      {:array, inner} -> decode_array(value, inner, constraints)
      resolved -> decode_scalar(value, resolved)
    end
  end

  defp decode_array(value, inner, constraints) when is_list(value) do
    item_constraints = Keyword.get(constraints, :items, [])
    Enum.map(value, &decode(&1, inner, item_constraints))
  end

  # A non-list for an array attribute means it went in as JSON.
  defp decode_array(value, _inner, _constraints) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp decode_array(value, _inner, _constraints), do: value

  # Types stored as JSON text have to come back as terms before cast_stored
  # sees them.
  defp decode_scalar(value, type) when is_binary(value) do
    cond do
      json_type?(type) ->
        case Jason.decode(value) do
          {:ok, decoded} -> decoded
          _ -> value
        end

      # The mirror of the base64 branch in encode/1.
      type == Ash.Type.Binary ->
        case Base.decode64(value) do
          {:ok, decoded} -> decoded
          :error -> value
        end

      true ->
        value
    end
  end

  defp decode_scalar(value, _type), do: value

  defp json_type?(type) do
    type in [
      Ash.Type.Map,
      Ash.Type.Keyword,
      Ash.Type.Tuple,
      Ash.Type.Struct,
      Ash.Type.Union,
      Ash.Type.Term
    ] or
      (is_atom(type) and function_exported?(type, :embedded?, 0) and type.embedded?())
  end
end
