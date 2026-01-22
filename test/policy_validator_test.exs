# SPDX-License-Identifier: PMPL-1.0-or-later
defmodule HttpCapabilityGateway.PolicyValidatorTest do
  use ExUnit.Case, async: true
  alias HttpCapabilityGateway.PolicyValidator

  describe "validate/1" do
    test "validates correct DSL v1 policy" do
      valid_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => [
            %{"path" => "/api/users", "verbs" => ["GET", "POST"]},
            %{"path" => "/health", "verbs" => ["GET"]}
          ]
        }
      }

      assert :ok = PolicyValidator.validate(valid_policy)
    end

    test "validates minimal policy" do
      minimal_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"]
        }
      }

      assert :ok = PolicyValidator.validate(minimal_policy)
    end

    test "rejects policy without dsl_version" do
      invalid_policy = %{
        "governance" => %{
          "global_verbs" => ["GET"]
        }
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "dsl_version"
    end

    test "rejects policy with unsupported dsl_version" do
      invalid_policy = %{
        "dsl_version" => "2",
        "governance" => %{
          "global_verbs" => ["GET"]
        }
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "dsl_version" or reason =~ "unsupported"
    end

    test "rejects policy without governance" do
      invalid_policy = %{
        "dsl_version" => "1"
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "governance"
    end

    test "rejects policy without global_verbs" do
      invalid_policy = %{
        "dsl_version" => "1",
        "governance" => %{}
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "global_verbs"
    end

    test "rejects policy with empty global_verbs" do
      invalid_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => []
        }
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "global_verbs" or reason =~ "empty"
    end

    test "rejects invalid HTTP verbs" do
      invalid_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "INVALID_VERB"]
        }
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "INVALID_VERB" or reason =~ "verb"
    end

    test "accepts all standard HTTP verbs" do
      standard_verbs = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]

      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => standard_verbs
        }
      }

      assert :ok = PolicyValidator.validate(policy)
    end

    test "validates route structure" do
      policy_with_routes = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{"path" => "/api", "verbs" => ["GET", "POST"]}
          ]
        }
      }

      assert :ok = PolicyValidator.validate(policy_with_routes)
    end

    test "rejects route without path" do
      invalid_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{"verbs" => ["GET"]}
          ]
        }
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "path"
    end

    test "rejects route without verbs" do
      invalid_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{"path" => "/api"}
          ]
        }
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "verbs"
    end

    test "rejects route with empty path" do
      invalid_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{"path" => "", "verbs" => ["GET"]}
          ]
        }
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "path" or reason =~ "empty"
    end

    test "accepts stealth configuration" do
      policy_with_stealth = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"]
        },
        "stealth" => %{
          "enabled" => true,
          "status_code" => 404
        }
      }

      assert :ok = PolicyValidator.validate(policy_with_stealth)
    end

    test "rejects invalid stealth status code" do
      invalid_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"]
        },
        "stealth" => %{
          "enabled" => true,
          "status_code" => 999
        }
      }

      assert {:error, reason} = PolicyValidator.validate(invalid_policy)
      assert reason =~ "status_code" or reason =~ "999"
    end

    test "accepts valid stealth status codes" do
      valid_codes = [200, 301, 302, 403, 404, 410, 500, 503]

      for code <- valid_codes do
        policy = %{
          "dsl_version" => "1",
          "governance" => %{
            "global_verbs" => ["GET"]
          },
          "stealth" => %{
            "enabled" => true,
            "status_code" => code
          }
        }

        assert :ok = PolicyValidator.validate(policy)
      end
    end

    test "accepts policy with regex paths" do
      policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET"],
          "routes" => [
            %{"path" => "/api/users/[0-9]+", "verbs" => ["GET"]},
            %{"path" => "/api/posts/.+", "verbs" => ["GET", "POST"]}
          ]
        }
      }

      assert :ok = PolicyValidator.validate(policy)
    end

    test "validates complex policy with multiple features" do
      complex_policy = %{
        "dsl_version" => "1",
        "governance" => %{
          "global_verbs" => ["GET", "POST"],
          "routes" => [
            %{"path" => "/api/v1/users", "verbs" => ["GET", "POST", "DELETE"]},
            %{"path" => "/api/v1/posts/[0-9]+", "verbs" => ["GET", "PUT"]},
            %{"path" => "/health", "verbs" => ["GET"]},
            %{"path" => "/metrics", "verbs" => ["GET"]}
          ]
        },
        "stealth" => %{
          "enabled" => false,
          "status_code" => 404
        }
      }

      assert :ok = PolicyValidator.validate(complex_policy)
    end
  end
end
