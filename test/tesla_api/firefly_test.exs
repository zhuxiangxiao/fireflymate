defmodule TeslaApi.FireflyTest do
  use ExUnit.Case, async: false

  alias TeslaApi.Firefly
  alias TeslaApi.Firefly.Config

  describe "Config parser" do
    test "parse_curl/1 parses curl command string with URL and headers" do
      curl = """
      curl 'http://example.com/api/v1/vehicle' -H 'User-Agent: Mozilla/5.0' -H 'Authorization: Bearer mytoken123'
      """

      {url, headers} = Config.parse_curl(curl)

      assert url == "http://example.com/api/v1/vehicle"
      assert {"User-Agent", "Mozilla/5.0"} in headers
      assert {"Authorization", "Bearer mytoken123"} in headers
    end

    test "parse_headers_string/1 parses multiline or semicolon headers" do
      headers_str = "Header1: Value1\nHeader2: Value2; Header3: Value3"
      headers = Config.parse_headers_string(headers_str)

      assert {"Header1", "Value1"} in headers
      assert {"Header2", "Value2"} in headers
      assert {"Header3", "Value3"} in headers
    end
  end

  describe "Firefly JSON converter" do
    setup do
      json_data = %{
        "hvac_status" => %{
          "temperature" => 30.5,
          "outside_temperature" => 32.5,
          "air_conditioner_on" => false,
          "sample_time" => 1788933622023
        },
        "light_status" => %{
          "head_light_on" => 0,
          "sample_time" => 1788933622023
        },
        "heating_status" => %{
          "sample_time" => 1788933027056,
          "steer_wheel_heat_sts" => 1,
          "seat_heat_frnt_le_sts" => 2,
          "seat_heat_frnt_ri_sts" => 0
        },
        "position_status" => %{
          "longitude" => 121.398937,
          "latitude" => 31.214289,
          "sample_time" => 1788933622023
        },
        "connection_status" => %{
          "connected" => true,
          "update_time" => 1788893605470
        },
        "offcar_mode_status" => %{
          "defender_mode" => 1
        },
        "window_status" => %{
          "win_front_left_posn" => 0,
          "sample_time" => 1788933030136
        },
        "exterior_status" => %{
          "vehicle_state" => 2,
          "mileage" => 2182,
          "sample_time" => 1788933622023
        },
        "soc_status" => %{
          "soc" => 76.0,
          "charge_state" => 0,
          "max_soc" => 100.0,
          "remaining_range" => 320.0,
          "remaining_actual_range" => 292.0,
          "charging_power" => 0.0,
          "charging_current" => 0.0,
          "sample_time" => 1788933622023
        },
        "tyre_status" => %{
          "front_left_wheel_press_bar" => 2.2,
          "front_right_wheel_press_bar" => 2.3,
          "rear_left_wheel_press_bar" => 2.3,
          "rear_right_wheel_press_bar" => 2.3
        },
        "vehicle_id" => "12bde4096e654e915708416010304010",
        "door_status" => %{
          "door_ajar_front_left_status" => 0,
          "vehicle_lock_status" => 1,
          "sample_time" => 1788933030136
        }
      }

      {:ok, json_data: json_data}
    end

    test "converts JSON data to TeslaApi.Vehicle struct", %{json_data: json_data} do
      vehicle = Firefly.convert_firefly_json(json_data)

      assert vehicle.id == "12bde4096e654e915708416010304010"
      assert vehicle.state == "online"
      assert vehicle.charge_state.battery_level == 76
      assert vehicle.climate_state.inside_temp == 30.5
      assert vehicle.climate_state.outside_temp == 32.5
      assert vehicle.climate_state.steering_wheel_heater == true
      assert vehicle.drive_state.latitude == 31.214289
      assert vehicle.drive_state.longitude == 121.398937
      assert vehicle.vehicle_state.sentry_mode == true
      assert vehicle.vehicle_state.locked == true
      assert vehicle.vehicle_state.tpms_pressure_fl == 2.2
    end
  end
end
