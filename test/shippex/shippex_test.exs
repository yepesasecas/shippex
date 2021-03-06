defmodule Shippex.ShippexTest do
  use ExUnit.Case
  doctest Shippex

  test "set env" do
    Application.put_env(:shippex, :env, :prod)
    assert Shippex.env == :prod

    Application.put_env(:shippex, :env, :foo)
    assert_raise Shippex.InvalidConfigError, &Shippex.env/0

    Application.put_env(:shippex, :env, :dev)
    assert Shippex.env == :dev
  end

  test "currency code" do
    Application.put_env(:shippex, :currency, :mxn)
    assert Shippex.currency_code == "MXN"

    Application.put_env(:shippex, :currency, :can)
    assert Shippex.currency_code == "CAN"

    Application.put_env(:shippex, :currency, :foo)
    assert_raise Shippex.InvalidConfigError, &Shippex.currency_code/0

    Application.put_env(:shippex, :currency, :usd)
    assert Shippex.currency_code == "USD"
  end

  test "fetch carrier module" do
    assert Shippex.Carrier.module(:ups) == Shippex.Carrier.UPS
    assert Shippex.Carrier.module(:usps) == Shippex.Carrier.USPS

    assert_raise RuntimeError, fn ->
      Shippex.Carrier.module(:invalid_carrier)
    end
  end
end
