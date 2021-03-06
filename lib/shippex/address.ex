defmodule Shippex.Address do
  @moduledoc """
  Represents an address that can be passed to other `Shippex` functions. Do
  *not* initialize this struct directly. Instead, use `address/1`.
  """

  @type t :: %__MODULE__{}

  @enforce_keys [:name, :company_name, :phone, :address, :address_line_2, :city, :state, :zip, :country]
  defstruct [:name, :company_name, :phone, :address, :address_line_2, :city, :state, :zip, :country]

  alias __MODULE__, as: Address
  alias Shippex.Util

  @doc """
  Initializes an `Address` struct from the given `params`, and performs minor
  validations that do not require any service requests.

      Shippex.Address.address(%{
        name: "Earl G",
        phone: "123-123-1234",
        address: "9999 Hobby Lane",
        address_line_2: nil,
        city: "Austin",
        state: "TX",
        zip: "78703"
      })
  """
  @spec address(map()) :: t
  def address(params) when is_map(params) do
    params = for {key, val} <- params, into: %{} do
      key = cond do
        is_atom(key) -> Atom.to_string(key)
        true -> key
      end

      val = cond do
        is_bitstring(val) -> String.trim(val)
        true -> val
      end

      {key, val}
    end

    address = %Address{
      name: params["name"],
      company_name: params["company_name"],
      phone: params["phone"],
      address: params["address"],
      address_line_2: params["address_line_2"],
      city: params["city"],
      state: Util.full_state_to_abbreviation(params["state"]),
      zip: String.replace(params["zip"], ~r/\s+/, ""),
      country: params["country"] || "US"
    }

    # Check for a passed array.
    address = case params["address"] do
      [line1] -> Map.put(address, :address, line1)

      [line1, line2 | _] ->
        address
        |> Map.put(:address, line1)
        |> Map.put(:address_line_2, line2)

      _ -> address
    end

    address
  end

  @doc """
  Returns the list of non-`nil` address lines. If no `address_line_2` is
  present, it returns a list of a single `String`.
  """
  @spec address_line_list(t) :: [String.t]
  def address_line_list(%Shippex.Address{} = address) do
    [address.address,
      address.address_line_2]
      |> Enum.reject(&is_nil/1)
  end
end
