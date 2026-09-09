defmodule TeslaApi.Firefly do
  @moduledoc """
  Firefly API integration module for fetching vehicle status and converting it into TeslaApi.Vehicle struct.
  """

  alias TeslaApi.Vehicle
  alias TeslaApi.Vehicle.State.{Charge, Climate, Drive, VehicleConfig, VehicleState}
  alias TeslaApi.Firefly.Config

  use Agent

  def client do
    Tesla.client(
      [
        {Tesla.Middleware.Headers, [{"user-agent", "TeslaMate/Firefly"}]},
        Tesla.Middleware.JSON
      ],
      {Tesla.Adapter.Finch, name: TeslaMate.HTTP, receive_timeout: 35_000}
    )
  end

  @doc """
  Starts the agent for keeping track of last known Firefly state (for speed calculations).
  """
  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{last_data: nil} end, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Fetches vehicle list for Firefly provider.
  """
  def list do
    case get_vehicle_data() do
      {:ok, vehicle} -> {:ok, [vehicle]}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches a single vehicle overview by id/eid.
  """
  def get(_id) do
    case get_vehicle_data() do
      {:ok, vehicle} -> {:ok, vehicle}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Fetches detailed vehicle data.
  """
  def get_with_state(_id) do
    case get_vehicle_data() do
      {:ok, vehicle} -> {:ok, vehicle}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Main API call to fetch raw Firefly JSON and transform it to `%Vehicle{}`.
  """
  def get_vehicle_data do
    {url, headers} = Config.get_config()

    tesla_headers = Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

    case Tesla.get(client(), url, headers: tesla_headers) do
      {:ok, %Tesla.Env{status: 200, body: %{"data" => data} = _body}} ->
        vehicle = convert_firefly_json(data)
        {:ok, vehicle}

      {:ok, %Tesla.Env{status: status, body: body}} ->
        {:error, %TeslaApi.Error{reason: :unknown, message: "Firefly HTTP #{status}: #{inspect(body)}"}}

      {:error, reason} ->
        {:error, %TeslaApi.Error{reason: :unknown, message: inspect(reason)}}
    end
  end

  @doc """
  Converts raw Firefly `data` map into `%TeslaApi.Vehicle{}` struct.
  """
  def convert_firefly_json(data) when is_map(data) do
    v_id = data["vehicle_id"] || System.get_env("FIREFLY_VEHICLE_ID", "12bde4096e654e915708416010304010")
    vin = System.get_env("FIREFLY_VIN", "NIOFIREFLY0000001")
    display_name = System.get_env("FIREFLY_VEHICLE_NAME", "Firefly")
    model_name = System.get_env("FIREFLY_MODEL", "Firefly")

    conn_status = data["connection_status"] || %{}
    connected = Map.get(conn_status, "connected", true)
    server_time = data["server_time"]

    state_str = if connected, do: "online", else: "offline"

    # Extract sub-maps
    ext_status = data["exterior_status"] || %{}
    soc_status = data["soc_status"] || %{}
    pos_status = data["position_status"] || %{}
    hvac_status = data["hvac_status"] || %{}
    door_status = data["door_status"] || %{}
    window_status = data["window_status"] || %{}
    tyre_status = data["tyre_status"] || %{}
    offcar_status = data["offcar_mode_status"] || %{}
    heating_status = data["heating_status"] || %{}

    # Timestamps
    sample_time =
      pos_status["sample_time"] || soc_status["sample_time"] || ext_status["sample_time"] ||
        (if server_time, do: server_time * 1000, else: System.system_time(:millisecond))

    # Odometer and mileage (input in km, converted to miles for TeslaApi internal representation)
    mileage_km = (ext_status["mileage"] || 0) * 1.0
    odometer_miles = km_to_miles(mileage_km)

    lat = pos_status["latitude"]
    lng = pos_status["longitude"]

    # Calculate speed & shift state
    {speed_mph, shift_state, calculated_power} =
      calculate_drive_metrics(lat, lng, mileage_km, sample_time, soc_status)

    # State structs construction
    charge_state = build_charge_state(soc_status, sample_time)
    climate_state = build_climate_state(hvac_status, heating_status, sample_time)
    drive_state = build_drive_state(lat, lng, speed_mph, shift_state, calculated_power, sample_time)
    vehicle_config = build_vehicle_config(model_name, ext_status, sample_time)
    vehicle_state = build_vehicle_state(display_name, odometer_miles, door_status, window_status, tyre_status, offcar_status, sample_time)

    %Vehicle{
      id: v_id,
      vehicle_id: v_id,
      vin: vin,
      state: state_str,
      display_name: display_name,
      charge_state: charge_state,
      climate_state: climate_state,
      drive_state: drive_state,
      vehicle_config: vehicle_config,
      vehicle_state: vehicle_state
    }
  end

  def convert_firefly_json(_), do: %Vehicle{}

  # Drive metrics calculation agent state
  defp calculate_drive_metrics(lat, lng, mileage_km, timestamp_ms, soc_status) do
    charging_power = (soc_status["charging_power"] || 0.0) * 1.0
    charging_current = (soc_status["charging_current"] || 0.0) * 1.0
    chrgr_plugin = soc_status["chrgr_plugin_sts"] || 0

    is_charging = charging_power > 0 or charging_current > 0 or chrgr_plugin > 0

    prev =
      if Process.whereis(__MODULE__) do
        Agent.get(__MODULE__, fn state -> state[:last_data] end)
      else
        nil
      end

    metrics =
      case prev do
        %{lat: plat, lng: plng, mileage_km: pmileage, ts: pts} when is_number(pts) and timestamp_ms > pts ->
          dt_hr = (timestamp_ms - pts) / 3_600_000.0

          # Distance by mileage diff first
          dist_km = max(0.0, mileage_km - pmileage)

          # Fallback to GPS distance if mileage didn't change but lat/lng did
          dist_km =
            if dist_km == 0.0 and (plat != lat or plng != lng) and lat != nil and plat != nil do
              haversine_distance_km({plat, plng}, {lat, lng})
            else
              dist_km
            end

          calc_speed_kmh = if dt_hr > 0, do: dist_km / dt_hr, else: 0.0

          # Filter extreme speed spikes (> 250 km/h)
          calc_speed_kmh = if calc_speed_kmh <= 250.0, do: calc_speed_kmh, else: 0.0

          calc_speed_mph = km_to_miles(calc_speed_kmh)

          shift =
            cond do
              is_charging -> "P"
              calc_speed_kmh > 1.0 -> "D"
              true -> "P"
            end

          power_kw = if shift == "D", do: 15.0, else: 0.0

          {calc_speed_mph, shift, power_kw}

        _ ->
          shift = if is_charging, do: "P", else: "P"
          {0.0, shift, 0.0}
      end

    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn state ->
        Map.put(state, :last_data, %{lat: lat, lng: lng, mileage_km: mileage_km, ts: timestamp_ms})
      end)
    end

    metrics
  end

  defp build_charge_state(soc, sample_time) do
    soc_val = (soc["soc"] || 0.0) * 1.0
    rem_range_km = (soc["remaining_range"] || 0.0) * 1.0
    rem_actual_km = (soc["remaining_actual_range"] || rem_range_km) * 1.0

    rem_range_miles = km_to_miles(rem_range_km)
    rem_actual_miles = km_to_miles(rem_actual_km)

    charging_power = (soc["charging_power"] || 0.0) * 1.0
    charging_current = (soc["charging_current"] || 0.0) * 1.0
    charging_voltage = (soc["charging_voltage"] || 0.0) * 1.0
    charge_state_enum = soc["charge_state"] || 0
    chrgr_plugin = soc["chrgr_plugin_sts"] || 0

    charging_status_str =
      cond do
        charging_power > 0 or charging_current > 0 -> "Charging"
        chrgr_plugin > 0 or charge_state_enum > 0 -> "Complete"
        true -> "Disconnected"
      end

    %Charge{
      battery_level: round(soc_val),
      usable_battery_level: round(soc_val),
      battery_range: rem_range_miles,
      ideal_battery_range: rem_range_miles,
      est_battery_range: rem_actual_miles,
      charger_power: round(charging_power),
      charger_actual_current: round(charging_current),
      charger_voltage: round(charging_voltage),
      charging_state: charging_status_str,
      charge_limit_soc: round((soc["max_soc"] || 100.0) * 1.0),
      charge_energy_added: (soc["chrg_eny"] || 0.0) * 1.0,
      timestamp: sample_time
    }
  end

  defp build_climate_state(hvac, heating, sample_time) do
    %Climate{
      inside_temp: (hvac["temperature"] || 20.0) * 1.0,
      outside_temp: (hvac["outside_temperature"] || 20.0) * 1.0,
      is_climate_on: hvac["air_conditioner_on"] == true,
      steering_wheel_heater: (heating["steer_wheel_heat_sts"] || 0) > 0,
      seat_heater_left: heating["seat_heat_frnt_le_sts"] || 0,
      seat_heater_right: heating["seat_heat_frnt_ri_sts"] || 0,
      timestamp: sample_time
    }
  end

  defp build_drive_state(lat, lng, speed_mph, shift_state, power, sample_time) do
    %Drive{
      latitude: (lat || 0.0) * 1.0,
      longitude: (lng || 0.0) * 1.0,
      speed: speed_mph,
      shift_state: shift_state,
      power: power,
      heading: 0,
      timestamp: sample_time
    }
  end

  defp build_vehicle_config(model_name, ext, sample_time) do
    %VehicleConfig{
      car_type: model_name,
      exterior_color: "White",
      wheel_type: "Standard",
      spoiler_type: "None",
      trim_badging: "Standard",
      timestamp: sample_time
    }
  end

  defp build_vehicle_state(display_name, odometer_miles, door, window, tyre, offcar, sample_time) do
    locked = door["vehicle_lock_status"] == 1 or door["vehicle_lock_status"] == true

    %VehicleState{
      vehicle_name: display_name,
      odometer: odometer_miles,
      locked: locked,
      df: door["door_ajar_front_left_status"] || 0,
      pf: door["door_ajar_front_right_status"] || 0,
      dr: door["door_ajar_rear_left_status"] || 0,
      pr: door["door_ajar_rear_right_status"] || 0,
      ft: door["engine_hood_ajar_status"] || 0,
      rt: door["tailgate_ajar_status"] || 0,
      fd_window: window["win_front_left_posn"] || 0,
      fp_window: window["win_front_right_posn"] || 0,
      rd_window: window["win_rear_left_posn"] || 0,
      rp_window: window["win_rear_right_posn"] || 0,
      sentry_mode: offcar["defender_mode"] == 1,
      tpms_pressure_fl: tyre["front_left_wheel_press_bar"],
      tpms_pressure_fr: tyre["front_right_wheel_press_bar"],
      tpms_pressure_rl: tyre["rear_left_wheel_press_bar"],
      tpms_pressure_rr: tyre["rear_right_wheel_press_bar"],
      timestamp: sample_time
    }
  end

  defp km_to_miles(km) when is_number(km), do: km * 0.621371
  defp km_to_miles(_), do: 0.0

  defp haversine_distance_km({lat1, lon1}, {lat2, lon2}) do
    r = 6371.0 # Earth radius in km
    dlat = :math.pi() * (lat2 - lat1) / 180.0
    dlon = :math.pi() * (lon2 - lon1) / 180.0
    lat1_rad = :math.pi() * lat1 / 180.0
    lat2_rad = :math.pi() * lat2 / 180.0

    a =
      :math.sin(dlat / 2.0) * :math.sin(dlat / 2.0) +
        :math.sin(dlon / 2.0) * :math.sin(dlon / 2.0) * :math.cos(lat1_rad) * :math.cos(lat2_rad)

    c = 2.0 * :math.atan2(:math.sqrt(a), :math.sqrt(1.0 - a))
    r * c
  end
end
