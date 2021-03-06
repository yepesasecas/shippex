defmodule Shippex.Carrier.USPS do
  @moduledoc false
  @behaviour Shippex.Carrier

  require EEx
  import SweetXml
  alias Shippex.Carrier.USPS.Client
  alias Shippex.{Package, Shipment, Util}

  @default_container :variable
  @large_containers ~w(rectangular nonrectangular variable)a

  for f <- ~w(address label package rate)a do
    EEx.function_from_file :defp, :"render_#{f}",
      __DIR__ <> "/usps/templates/#{f}.eex", [:assigns]
  end

  defmacro with_response(response, do: block) do
    quote do
      case unquote(response) do
        {:ok, %{body: body}} ->
          case xpath(body, ~x"//Error//text()"s) do
            "" ->
              var!(body) = body
              unquote(block)
            error ->
              code = xpath(body, ~x"//Error//Number//text()"s)
              message = xpath(body, ~x"//Error//Description//text()"s)
              {:error, %{code: code, message: message}}
          end

        {:error, _} ->
          {:error, %{code: 1, message: "The USPS API is down."}}
      end
    end
  end

  def fetch_rates(%Shippex.Shipment{} = shipment) do
    fetch_rate(shipment, :all)
  end

  def fetch_rate(%Shippex.Shipment{} = shipment, service) do
    service = case service do
      %Shippex.Service{} = service -> service.code
      :all -> "ALL"
      s when is_bitstring(s) -> s
    end

    if shipment.international? do
      international_rate_request(shipment)
    else
      domestic_rate_request(shipment, service)
    end
  end
  defp domestic_rate_request(shipment, service) do
    # Convert weight to ounces
    package = shipment.package

    rate = render_rate shipment: shipment, service: service

    with_response Client.post("ShippingAPI.dll", %{API: "RateV4", XML: rate}) do
      body
      |> xpath(
        ~x"//RateV4Response//Package//Postage"l,
        name: ~x"./MailService//text()"s |> transform_by(&strip_html/1),
        service: ~x"./MailService//text()"s |> transform_by(&service_to_code/1),
        rate: ~x"./Rate//text()"s |> transform_by(&Util.price_to_cents/1)
      )
      |> Enum.map(fn(%{name: description, service: service, rate: cents}) ->
        rate = %Shippex.Rate{service: %{service | description: description},
                             price: cents}

        {:ok, rate}
      end)
      |> Enum.filter(fn {:ok, rate} ->
        case rate.service.code do
          "LIBRARY MAIL" -> config().include_library_mail
          "MEDIA MAIL" -> config().include_media_mail
          _ -> true
        end
      end)
    end
  end
  defp international_rate_request(shipment) do
    package_params =
      {:Package, %{ID: "0"},
        [{:Pounds, nil, shipment.package.weight},
         {:Ounces, nil, "0"},
         {:Machinable, nil, "False"},
         {:MailType, nil, international_mail_type(shipment.package)},
         {:ValueOfContents, nil, shipment.package.monetary_value},
         {:Country, nil, Util.abbreviation_to_country_name(shipment.to.country)}] ++
        container(shipment) ++
        [{:OriginZip, nil, shipment.from.zip}]}

    request =
      {:IntlRateV2Request, %{USERID: config().username},
        [{:Revision, nil, 2}, package_params]}

    with_response Client.post("ShippingAPI.dll", %{API: "IntlRateV2", XML: request}) do
      body
      |> xpath(
        ~x"//IntlRateV2Response//Package//Service"l,
        name: ~x"./SvcDescription//text()"s,
        service: ~x"./SvcDescription//text()"s |> transform_by(&service_to_code/1),
        rate: ~x"./Postage//text()"s |> transform_by(&Util.price_to_cents/1)
      )
      |> Enum.map(fn(%{name: description, service: service, rate: cents}) ->
        rate = %Shippex.Rate{service: %{service | description: description},
                             price: cents}

        {:ok, rate}
      end)
    end
  end

  defp weight_in_ounces(%Shipment{package: %Package{weight: weight}}) do
    16 * case Application.get_env(:shippex, :weight_unit, :lbs) do
      :lbs -> weight
      :kg -> Shippex.Util.kgs_to_lbs(weight)
      u ->
        raise """
        Invalid unit of measurement specified: #{IO.inspect(u)}

        Must be either :lbs or :kg
        """
    end
  end

  defp service_to_code(description) do
    code = cond do
      description =~ ~r/priority mail international/i -> "PRIORITY MAIL INTERNATIONAL"
      description =~ ~r/priority mail express/i -> "PRIORITY MAIL EXPRESS"
      description =~ ~r/priority/i -> "PRIORITY"
      description =~ ~r/first[-\s]*class/i -> "FIRST CLASS"
      description =~ ~r/retail ground/i -> "RETAIL GROUND"
      description =~ ~r/media mail/i -> "MEDIA MAIL"
      description =~ ~r/library mail/i -> "LIBRARY MAIL"
    end

    Shippex.Service.by_carrier_and_code(:usps, code)
  end

  defp international_mail_type(%Shippex.Package{container: nil}), do: "ALL"
  defp international_mail_type(%Shippex.Package{container: container}) do
    container = "#{container}"
    cond do
      container =~ ~r/envelope/i -> "ENVELOPE"
      container =~ ~r/flat[-\s]*rate/i -> "FLATRATE"
      container =~ ~r/rectangular|variable/i -> "PACKAGE"
      true -> "ALL"
    end
  end

  def fetch_label(%Shippex.Shipment{} = shipment, %Shippex.Service{} = service) do
    request = render_label shipment: shipment, service: service

    with_response Client.post("ShippingAPI.dll", %{API: "eVS", XML: request}) do
      data =
        body
        |> xpath(
          ~x"//eVSResponse",
          rate: ~x"//Postage//text()"s,
          tracking_number: ~x"//BarcodeNumber//text()"s,
          image: ~x"//LabelImage//text()"s
        )

      price = Util.price_to_cents(data.rate)

      rate = %Shippex.Rate{service: service, price: price}
      image = String.replace(data.image, "\n", "")
      label = %Shippex.Label{rate: rate,
                             tracking_number: data.tracking_number,
                             format: :tiff,
                             image: image}

      {:ok, label}
    end
  end

  def cancel_shipment(%Shippex.Label{} = label) do
    cancel_shipment(label.tracking_number)
  end
  def cancel_shipment(tracking_number) when is_bitstring(tracking_number) do
  end

  def validate_address(%Shippex.Address{country: "US"} = address) do
    request =
      {:AddressValidateRequest, %{USERID: config().username},
        [{:Revision, nil, "1"},
         {:Address, %{ID: "0"}, render_address(address: address, firm: "FirmName")}]}

    with_response Client.post("", %{API: "Verify", XML: request}) do
      candidates =
        body
        |> xpath(
          ~x"//AddressValidateResponse//Address"l,
          address: ~x"./Address2//text()"s, # USPS swaps address lines 1 & 2
          address_line_2: ~x"./Address1//text()"s,
          city: ~x"./City//text()"s,
          state: ~x"./State//text()"s,
          zip: ~x"./Zip5//text()"s
        )
        |> Enum.map(fn (candidate) ->
          candidate
          |> Map.merge(Map.take(address, [:name, :phone]))
          |> Shippex.Address.address
        end)

      {:ok, candidates}
    end
  end

  defp container(%Shipment{package: package}) do
    case Package.usps_containers[package.container] do
      nil -> Package.usps_containers[@default_container]
      container -> container
    end
    |> String.upcase
  end

  defp size(%Shipment{package: package}) do
    is_large? = if package.container in @large_containers do
      package
      |> Map.take(~w(large width height)a)
      |> Map.values
      |> Enum.any?(& &1 > 12)
    end

    if is_large?, do: "LARGE", else: "REGULAR"
  end

  defp strip_html(string) do
    string
    |> HtmlEntities.decode
    |> String.replace(~r/<\/?\w+>.*<\/\w+>/, "")
  end

  defp config do
    with cfg when is_list(cfg) <- Keyword.get(Shippex.config, :usps, {:error, :not_found}),

         un <-
           Keyword.get(cfg, :username, {:error, :not_found, :username}),

         pw <-
           Keyword.get(cfg, :password, {:error, :not_found, :password}),

         include_library_mail <-
           Keyword.get(cfg, :include_library_mail, true),

         include_media_mail <-
           Keyword.get(cfg, :include_media_mail, true) do

         %{username: un,
           password: pw,
           include_library_mail: include_library_mail,
           include_media_mail: include_media_mail}
    else
      {:error, :not_found, token} -> raise Shippex.InvalidConfigError,
        message: "USPS config key missing: #{token}"

      {:error, :not_found} -> raise Shippex.InvalidConfigError,
        message: "USPS config is either invalid or not found."
    end
  end
end
