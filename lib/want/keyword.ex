defmodule Want.Keyword do
  @moduledoc """
  Manages conversions to and from keyword lists.
  """

  @type input       :: Want.enumerable()
  @type schema      :: map()
  @type key         :: binary() | atom()
  @type opts        :: Keyword.t()
  @type result      :: {:ok, result :: Keyword.t()} | {:error, reason :: binary()}
  @type enumerable  :: Want.enumerable()

  defimpl Want.Dump, for: List do
    @doc """
    Dump a keyword list value to a keyword list. All values inside the keyword list will
    be dumped using the associated `Want` module `dump/1` clauses.
    """
    @spec dump(Want.enumerable(), keyword()) :: {:ok, keyword()} | {:error, term()}
    def dump(input, _opts) do
      input
      |> Enum.reduce_while([], fn({k, v}, out) ->
        case Want.dump(v) do
          {:ok, v} ->
            {:cont, [{k, v} | out]}
          {:error, reason} ->
            {:halt, "Failed to dump value for key #{k}: #{inspect reason}"}
        end
      end)
      |> case do
        kv when is_list(kv) ->
          {:ok, Enum.sort_by(kv, fn {k, _} -> k end, :asc)}
        error ->
          {:error, error}
      end
    end
  end

  defimpl Want.Update, for: List do
    @doc """
    Update a Keyword list type. For every key specified in the new value, corresponding
    keys in the old value will be updated using the `Want.Update` protocol. Any
    keys in :new that do not exist in :old will be added.
    """
    @spec update(keyword(), Want.enumerable()) :: {:ok, keyword()}
    def update(old, new) when is_map(new) or is_list(new) do
      {:ok, new
      |> Enum.reduce(old, fn({key, value}, out) ->
        Keyword.update(out, key, value, fn v ->
          case Want.Update.update(v, value) do
            {:ok, new} ->
              new
            {:error, _reason} ->
              v
          end
        end)
      end)}
    end
  end

  @doc """
  Cast an incoming keyword list or map to an output keyword list using the
  provided schema to control conversion rules and validations.

  ## Examples

      iex> Want.Keyword.cast(%{"id" => 1}, %{id: [type: :integer]})
      {:ok, [id: 1]}

      iex> Want.Keyword.cast(%{"archived" => "true"}, %{archived: [type: :boolean, default: false]})
      {:ok, [archived: true]}

      iex> Want.Keyword.cast(%{"archived" => "false"}, %{archived: [type: :boolean, default: false]})
      {:ok, [archived: false]}

      iex> Want.Keyword.cast(%{}, %{archived: [type: :boolean, default: false]})
      {:ok, [archived: false]}

      iex> Want.Keyword.cast(%{}, %{id: [type: :integer, default: 1]})
      {:ok, [id: 1]}

      iex> Want.Keyword.cast(%{"id" => "bananas"}, %{id: [type: :integer, default: 1]})
      {:ok, [id: 1]}

      iex> Want.Keyword.cast(%{"hello" => "world", "foo" => "bar"}, %{hello: [], foo: [type: :atom]})
      {:ok, [hello: "world", foo: :bar]}

      iex> Want.Keyword.cast(%{"hello" => "world"}, %{hello: [], foo: [required: true]})
      {:error, "Failed to cast key foo (key :foo not found) and no default value provided."}

      iex> Want.Map.cast(%{"datetime" => DateTime.from_unix!(0)}, %{datetime: [type: :datetime]})
      {:ok, %{datetime: DateTime.from_unix!(0)}}

      iex> Want.Map.cast(%{"datetime" => "1970-01-01T00:00:00Z"}, %{datetime: [type: :datetime]})
      {:ok, %{datetime: DateTime.from_unix!(0)}}

      iex> Want.Keyword.cast(%{"hello" => "world"}, %{hello: [], foo: []})
      {:ok, [hello: "world"]}

      iex> Want.Keyword.cast(%{"hello" => "world"}, %{hello: [type: :enum, valid: [:world]]})
      {:ok, [hello: :world]}

      iex> Want.Keyword.cast(%{"hello" => %{"foo" => "bar"}}, %{hello: %{foo: [type: :atom]}})
      {:ok, [hello: [foo: :bar]]}

      iex> Want.Keyword.cast(%{"id" => "bananas"}, %{id: [type: :integer, default: 1]}, merge: [id: 2])
      {:ok, [id: 2]}

      iex> Want.Keyword.cast(%{"id" => "bananas"}, %{id: [type: :any]})
      {:ok, [id: "bananas"]}

      iex> Want.Keyword.cast(%{"a" => %{"b" => %{"c" => 100}}}, %{id: [type: :integer, from: {"a", "b", "c"}]})
      {:ok, [id: 100]}

      iex> Want.Keyword.cast(%{"a" => [1, 2, 3, 4]}, %{a: [type: {:array, :integer}]})
      {:ok, [a: [1, 2, 3, 4]]}

      iex> Want.Keyword.cast(%{"a" => %{"b" => %{"c" => 100}}}, %{id: [type: :integer, from: {"a", "b", "c"}, transform: fn x -> x * 2 end]})
      {:ok, [id: 200]}

  """
  @spec cast(value :: input(), schema :: schema()) :: result()
  def cast(input, schema),
    do: cast(input, schema, [])
  @spec cast(value :: input(), schema :: schema(), opts :: Keyword.t()) :: result()
  def cast(input, {:array, type}, opts) when is_list(input) do
    Enum.reduce_while(input, {:ok, []}, fn(elem, {:ok, out}) ->
      case cast(elem, type, opts) do
        {:ok, value}      -> {:cont, {:ok, [maybe_transform(value, opts) | out]}}
        {:error, reason}  -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, list}   -> {:ok, Enum.reverse(list)}
      other         -> other
    end
  end
  def cast(input, schema, opts) when is_map(schema) and (is_list(input) or is_map(input)) and not is_atom(schema) do
    schema
    |> Enum.reduce_while([], fn({key, field_opts}, out) ->
      with  {:error, reason}      <- cast(input, field_opts[:from] || key, field_opts),
            {false, _reason}      <- {is_map(field_opts), reason},
            {{:ok, default}, _}   <- {merge_or_default(key, field_opts, opts), reason} do
        {:cont, Keyword.put(out, key, maybe_transform(default, field_opts))}
      else
        {:ok, value} ->
          {:cont, Keyword.put(out, key, maybe_transform(value, field_opts))}
        {true, reason} ->
          {:halt, {:error, "Failed to cast key #{key} to map: #{reason}"}}
        {{:error, :no_default}, reason} ->
          if field_opts[:required] do
            {:halt, {:error, "Failed to cast key #{key} (#{reason}) and no default value provided."}}
          else
            {:cont, out}
          end
      end
    end)
    |> case do
      result when is_list(result) ->
        {:ok, result}
      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec cast(input :: any(), key :: key() | list(key()), opts :: opts() | map()) :: {:ok, result :: any()} | {:error, reason :: binary()}
  def cast(_input, [], _opts),
    do: {:error, "key not found"}
  def cast(input, [key | t], opts) do
    case cast(input, key, opts) do
      {:ok, v}    -> {:ok, v}
      {:error, _} -> cast(input, t, opts)
    end
  end
  def cast(input, key, opts) when is_tuple(key) and (is_list(input) or is_map(input)) do
    key
    |> :erlang.tuple_to_list()
    |> Enum.reduce_while({input, :error}, fn
      (key, {input, _out}) when is_binary(key) and (is_list(input) or is_map(input))  ->
        input
        |> Enum.find(fn
          {k, _v} when is_atom(k)     -> Atom.to_string(k) == key
          {k, _v} when is_binary(k)   -> k == key
          _                           -> false
        end)
        |> case do
          {_, v}  -> {:cont, {v, :ok}}
          nil     -> {:halt, {input, :error}}
        end
      (key, {input, _out}) when is_atom(key) and (is_list(input) or is_map(input))  ->
        input
        |> Enum.find(fn
          {k, _v} when is_atom(k)     -> k == key
          {k, _v} when is_binary(k)   -> k == Atom.to_string(key)
          _                           -> false
        end)
        |> case do
          {_, v}  -> {:cont, {v, :ok}}
          nil     -> {:halt, {input, :error}}
        end
      (_key, {input, _out}) ->
        {:halt, {input, :error}}
    end)
    |> case do
      {v, :ok}      -> cast(v, type(opts), opts)
      {_v, :error}  -> {:error, :key_not_found}
    end
  end
  def cast(input, key, opts) when (is_list(input) or (is_map(input) and not is_struct(input))) and is_binary(key) and not is_nil(key) do
    input
    |> Enum.find(fn
      {k, _v} when is_atom(k)     -> Atom.to_string(k) == key
      {k, _v} when is_binary(k)   -> k == key
      _                           -> false
    end)
    |> case do
      {_, v}  -> cast(v, type(opts), opts)
      nil     -> {:error, "key #{inspect key} not found"}
    end
  end
  def cast(input, key, opts) when (is_list(input) or (is_map(input) and not is_struct(input))) and not is_nil(key) and is_atom(key) do
    if Want.Shape.is_shape?(key) do
      Want.Shape.cast(key, input)
    else
      input
      |> Enum.find(fn
        {k, _v} when is_atom(k)     -> k == key
        {k, _v} when is_binary(k)   -> k == Atom.to_string(key)
        _                           -> false
      end)
      |> case do
        {_, v}  -> cast(v, type(opts), opts)
        nil     -> {:error, "key #{inspect key} not found"}
      end
    end
  end
  def cast(input, nil, opts) when is_map(opts),
    do: cast(input, opts)
  def cast(input, :boolean, opts),
    do: Want.Boolean.cast(input, opts)
  def cast(input, :integer, opts),
    do: Want.Integer.cast(input, opts)
  def cast(input, :string, opts),
    do: Want.String.cast(input, opts)
  def cast(input, :float, opts),
    do: Want.Float.cast(input, opts)
  def cast(input, :atom, opts),
    do: Want.Atom.cast(input, opts)
  def cast(input, :sort, opts),
    do: Want.Sort.cast(input, opts)
  def cast(input, :enum, opts),
    do: Want.Enum.cast(input, opts)
  def cast(input, :datetime, opts),
    do: Want.DateTime.cast(input, opts)
  def cast(input, :date, opts),
    do: Want.Date.cast(input, opts)
  def cast(input, :any, _opts),
    do: {:ok, input}
  def cast(_input, type, _opts),
    do: {:error, "unknown cast type #{inspect type} specified"}

  #
  # Attempt to generate a value for a given key, either using the cast options'
  # `merge` keywords or a default value from the field options.
  #
  defp merge_or_default(key, field_opts, cast_opts) do
    cond do
      Keyword.has_key?(Keyword.get(cast_opts, :merge, []), key) ->
        {:ok, Keyword.get(Keyword.get(cast_opts, :merge, %{}), key)}
      Keyword.has_key?(field_opts, :default) ->
        {:ok, field_opts[:default]}
      true ->
        {:error, :no_default}
    end
  end

  #
  # Conditionally apply a transformation to a derived value based on whether the
  # `:transform` option has been specified and is valid.
  #
  @spec maybe_transform(term(), Keyword.t()) :: term()
  defp maybe_transform(value, opts) when is_list(opts) do
    with  true  <- Keyword.has_key?(opts, :transform),
          true  <- Kernel.is_function(opts[:transform], 1) do
      Kernel.apply(opts[:transform], [value])
    else
      _ -> value
    end
  end
  defp maybe_transform(value, _),
    do: value

  #
  # Pull a type specified from a set of options
  #
  defp type(opts) when is_list(opts),
    do: Keyword.get(opts, :type, :string)
  defp type(opts) when is_map(opts),
    do: nil
end
